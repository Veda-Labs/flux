// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {BoringVault} from "src/BoringVault.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {IDatum} from "src/interfaces/IDatum.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Manager used for Flux Boring Vaults
///
/// @dev
/// This contract is responsible for gating calls the boring vault can make
/// and for abstratcing the total assets calculation down to a flux function.
abstract contract FluxManager is Auth {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ENUMS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Performance metrics used to measure vault performance
    /// @param TOKEN0 Measures accumulation of token0
    /// @param TOKEN1 Measures accumulation of token1
    /// @param FLUX Measures accumulation of wide range liquidity
    enum PerformanceMetric {
        TOKEN0,
        TOKEN1,
        FLUX
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint16 internal constant BPS_SCALE = 10_000;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Used to pause calls to `FluxManager`.
     */
    bool public isPaused;

    // TODO add setters
    IDatum public datum;
    uint16 public datumLowerBound;
    uint16 public datumUpperBound;

    // TODO I think its okay to allow people to change their performance metric, as long as fees are paid, and highwatermark is reset.
    PerformanceMetric public performanceMetric;
    uint16 public performanceFee;
    uint128 highwatermark;
    address public payout;
    uint128 pendingFee;
    uint128 totalSupplyLastReview;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error FluxManager__Paused();
    error FluxManager__InvalidExchangeRate(uint256 provided);
    error FluxManager__WrongMetric();
    error FluxManager__NotImplemented();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused();
    event Unpaused();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       MODIFIERS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // TODO if this error happened in the datum then we could provide the exchange rate, lower and upper
    modifier checkDatum(uint256 exchangeRate) {
        if (!datum.validateExchangeRateWithDatum(exchangeRate, decimals1, datumLowerBound, datumUpperBound)) {
            revert FluxManager__InvalidExchangeRate(exchangeRate);
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    BoringVault internal immutable boringVault;
    ERC20 public immutable token0;
    ERC20 public immutable token1;
    uint8 internal immutable decimals0;
    uint8 internal immutable decimals1;
    uint8 internal immutable decimalsBoring;
    bool internal immutable baseIn0Or1;

    constructor(
        address _owner,
        address _boringVault,
        address _token0,
        address _token1,
        bool _baseIn0Or1,
        address _datum,
        uint16 _datumLowerBound,
        uint16 _datumUpperBound
    ) Auth(_owner, Authority(address(0))) {
        boringVault = BoringVault(payable(_boringVault));
        token0 = ERC20(_token0);
        token1 = ERC20(_token1);
        decimals0 = _token0 == address(0) ? 18 : token0.decimals();
        decimals1 = token1.decimals();
        decimalsBoring = boringVault.decimals();
        baseIn0Or1 = _baseIn0Or1;
        datum = IDatum(_datum);
        // TODO validate these
        datumLowerBound = _datumLowerBound;
        datumUpperBound = _datumUpperBound;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ADMIN FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Pause this contract, which prevents future calls to `FluxManager`.
    /// @dev Callable by MULTISIG_ROLE.
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    /// @notice Unpause this contract, which allows future calls to `FluxManager`.
    /// @dev Callable by MULTISIG_ROLE.
    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    FLUX ACCOUNTING                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function refreshInternalFluxAccounting() external requiresAuth {
        _refreshInternalFluxAccounting();
    }

    // TODO performance fee calculation
    // 3 options share price relative to
    // 1) token0
    // 2) token1
    // 3) flux, liquidity of max range position, think this needs to be a virtual function that things can optionally implement

    // TODO can this be abstracted to a pending fee function
    /// @dev datum checked via getRateSafe call
    /// @dev pending fee is not incorporated into new highwatermark or into totalAssets, to reduce complexity
    // It can be safely assumed that fees will regularly be taken
    function calculatePerformanceRelativeToTokens(uint256 exchangeRate) external requiresAuth {
        if (performanceMetric != PerformanceMetric.TOKEN0 || performanceMetric != PerformanceMetric.TOKEN1) {
            revert FluxManager__WrongMetric();
        }

        uint256 accumulatedPerShare;
        if (performanceMetric == PerformanceMetric.TOKEN0) {
            accumulatedPerShare = getRateSafe(exchangeRate, true);
        } else {
            accumulatedPerShare = getRateSafe(exchangeRate, false);
        }

        uint256 currentHighwatermark = highwatermark;
        if (accumulatedPerShare > currentHighwatermark) {
            uint256 delta = accumulatedPerShare - currentHighwatermark;
            uint256 currentTotalSupply = boringVault.totalSupply();
            uint256 totalSupply = currentTotalSupply;
            // Use minimum
            if (totalSupply > totalSupplyLastReview) {
                totalSupply = totalSupplyLastReview;
            }
            uint256 performance = delta.mulDivDown(totalSupply, 10 ** decimalsBoring);
            // Update pendingFee
            pendingFee = SafeCast.toUint128(performance.mulDivDown(performanceFee, BPS_SCALE));
            // Update highwatermark
            highwatermark = SafeCast.toUint128(accumulatedPerShare);
            // Update totalSupplyLastReview
            totalSupplyLastReview = SafeCast.toUint128(currentTotalSupply);
        }
    }

    function calculatePerformanceRelativeToFlux(
        uint256 exchangeRate,
        uint256, /*optimalToken0Balance*/
        uint256 /*optimalToken1Balance*/
    ) external virtual requiresAuth checkDatum(exchangeRate) {
        revert FluxManager__NotImplemented();
    }
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       FLUX VIEW                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // ExchangeRate provided in terms of token1 decimals
    function totalAssets(uint256 exchangeRate, bool quoteIn0Or1)
        public
        view
        checkDatum(exchangeRate)
        returns (uint256 assets)
    {
        (uint256 token0Assets, uint256 token1Assets) = _totalAssets(exchangeRate);
        if (quoteIn0Or1) {
            // Return totalAssets in token0
            uint256 converted = token1Assets * (10 ** decimals0);
            converted = converted.mulDivDown(10 ** decimals1, exchangeRate);
            converted /= 10 ** decimals1;
            assets = token0Assets + converted;
        } else {
            // Return totalAssets in token1
            uint256 converted = token0Assets * (10 ** decimals1);
            converted = converted.mulDivDown(exchangeRate, 10 ** decimals1);
            converted /= 10 ** decimals0;
            assets = token1Assets + converted;
        }
    }

    function totalAssets(uint256 exchangeRate)
        external
        view
        checkDatum(exchangeRate)
        returns (uint256 token0Assets, uint256 token1Assets)
    {
        return _totalAssets(exchangeRate);
    }

    function getRate(uint256 exchangeRate, bool quoteIn0Or1) public view checkDatum(exchangeRate) returns (uint256) {
        uint256 ts = boringVault.totalSupply();
        if (ts == 0) {
            if (baseIn0Or1 && quoteIn0Or1) {
                return 10 ** decimals0;
            } else if (!baseIn0Or1 && quoteIn0Or1) {
                return uint256(10 ** decimals0).mulDivDown(10 ** decimals1, exchangeRate);
            } else if (baseIn0Or1 && !quoteIn0Or1) {
                return uint256(10 ** decimals1).mulDivDown(exchangeRate, 10 ** decimals1);
            } else if (!baseIn0Or1 && !quoteIn0Or1) {
                return 10 ** decimals1;
            } else {
                // Generic revert as we will never actually reach this branch.
                revert();
            }
        } else {
            uint256 ta = totalAssets(exchangeRate, quoteIn0Or1);
            return ta.mulDivDown(10 ** decimalsBoring, ts);
        }
    }

    function getRateSafe(uint256 exchangeRate, bool quoteIn0Or1) public view returns (uint256) {
        if (isPaused) revert FluxManager__Paused();
        return getRate(exchangeRate, quoteIn0Or1);
    }

    /// @notice this function SHOULD revert if totalSupply is zero
    function shareComposition(uint256 exchangeRate)
        public
        view
        checkDatum(exchangeRate)
        returns (uint256 token0PerShare, uint256 token1PerShare)
    {
        uint256 ts = boringVault.totalSupply();
        (uint256 ta0, uint256 ta1) = _totalAssets(exchangeRate);
        token0PerShare = ta0.mulDivDown(10 ** decimalsBoring, ts);
        token1PerShare = ta1.mulDivDown(10 ** decimalsBoring, ts);
    }

    /// @notice this function SHOULD revert if totalSupply is zero
    function shareCompositionSafe(uint256 exchangeRate)
        external
        view
        returns (uint256 token0PerShare, uint256 token1PerShare)
    {
        if (isPaused) revert FluxManager__Paused();
        return shareComposition(exchangeRate);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ABSTRACT FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Refresh internal flux constants(like ERC20 token balances)
    function _refreshInternalFluxAccounting() internal virtual;

    function _totalAssets(uint256 exchangeRate)
        internal
        view
        virtual
        returns (uint256 token0Assets, uint256 token1Assets);
}
