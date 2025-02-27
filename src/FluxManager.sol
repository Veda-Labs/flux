// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {BoringVault} from "src/BoringVault.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {IDatum} from "src/interfaces/IDatum.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WETH} from "@solmate/src/tokens/WETH.sol";

import {console} from "@forge-std/Test.sol";

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
    /// @param LIQUIDITY Measures accumulation of wide range liquidity
    enum PerformanceMetric {
        TOKEN0,
        TOKEN1,
        LIQUIDITY
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

    PerformanceMetric public performanceMetric;
    uint16 public performanceFee;
    uint64 public lastPerformanceReview;
    uint64 public performanceReviewFrequency;
    uint128 highWatermark;
    address public payout;
    uint128 public pendingFee;
    uint128 totalSupplyLastReview;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error FluxManager__Paused();
    error FluxManager__InvalidExchangeRate(uint256 provided);
    error FluxManager__WrongMetric();
    error FluxManager__NotImplemented();
    error FluxManager__TooSoon();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused();
    event Unpaused();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       MODIFIERS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier checkDatum(uint256 exchangeRate) {
        datum.validateExchangeRateWithDatum(exchangeRate, decimals1, datumLowerBound, datumUpperBound);
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
    bool internal immutable baseIn0Or1; // Only used for initial share price when zero shares outstanding
    address internal immutable nativeWrapper;

    constructor(
        address _owner,
        address _boringVault,
        address _token0,
        address _token1,
        bool _baseIn0Or1,
        address _nativeWrapper,
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
        nativeWrapper = _nativeWrapper;
        datum = IDatum(_datum);
        // TODO validate these
        datumLowerBound = _datumLowerBound;
        datumUpperBound = _datumUpperBound;

        performanceFee = 0.2e4; //TODO make this settable
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

    /// @dev pending fee is not incorporated into new highWatermark or into totalAssets, to reduce complexity
    // It can be safely assumed that fees will regularly be taken
    function reviewPerformance() external requiresAuth {
        // Make sure we are not paused.
        if (isPaused) revert FluxManager__Paused();

        // Make sure enough time has passed.
        uint256 currentTime = block.timestamp;
        uint256 timeDelta = currentTime - lastPerformanceReview;
        if (timeDelta < performanceReviewFrequency) revert FluxManager__TooSoon();

        _refreshInternalFluxAccounting();

        (uint256 accumulatedPerShare, uint256 currentHighWatermark, uint256 currentTotalSupply, uint256 feeOwed) =
            previewPerformance();

        if (accumulatedPerShare > currentHighWatermark) {
            // Update highWatermark
            highWatermark = SafeCast.toUint128(accumulatedPerShare);
        }
        if (feeOwed > 0) {
            // Update pendingFee
            pendingFee += SafeCast.toUint128(feeOwed);
        }
        // Update totalSupplyLastReview
        totalSupplyLastReview = SafeCast.toUint128(currentTotalSupply);
        // Update lastPerformanceReview
        lastPerformanceReview = uint64(currentTime);
    }

    function resetHighWatermark() external requiresAuth {
        _resetHighWatermark();
    }

    function claimFees(bool token0Or1) external requiresAuth {
        _claimFees(token0Or1);
    }

    /// @dev if there are pending fees this will forfeit them.
    function switchPerformanceMetric(PerformanceMetric newMetric, bool token0Or1) external requiresAuth {
        _claimFees(token0Or1);
        performanceMetric = newMetric;
        _refreshInternalFluxAccounting();
        _resetHighWatermark();
    }

    function setPayout(address newPayout) external requiresAuth {
        payout = newPayout;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       FLUX VIEW                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function previewPerformance()
        public
        view
        returns (uint256 accumulatedPerShare, uint256 currentHighWatermark, uint256 currentTotalSupply, uint256 feeOwed)
    {
        (accumulatedPerShare, currentTotalSupply) = _getAccumulatedPerShareBasedOffMetric();

        currentHighWatermark = highWatermark;
        if (accumulatedPerShare > currentHighWatermark) {
            if (performanceFee > 0) {
                uint256 delta = accumulatedPerShare - currentHighWatermark;
                // Use minimum
                uint256 minShares =
                    currentTotalSupply > totalSupplyLastReview ? totalSupplyLastReview : currentTotalSupply;

                uint256 performance = delta.mulDivDown(minShares, 10 ** decimalsBoring);
                // Update pendingFee
                feeOwed = SafeCast.toUint128(performance.mulDivDown(performanceFee, BPS_SCALE));
            }
        }
    }

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
    /*                     FLUX INTERNAL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getAccumulatedPerShareBasedOffMetric()
        internal
        view
        returns (uint256 accumulatedPerShare, uint256 currentTotalSupply)
    {
        uint256 accumulated;
        uint256 exchangeRate = datum.getDatumInDecimals(decimals1);
        if (performanceMetric == PerformanceMetric.TOKEN0) {
            accumulated = totalAssets(exchangeRate, true);
        } else if (performanceMetric == PerformanceMetric.TOKEN1) {
            accumulated = totalAssets(exchangeRate, false);
        } else if (performanceMetric == PerformanceMetric.LIQUIDITY) {
            accumulated = _totalLiquidity(exchangeRate);
        }

        currentTotalSupply = boringVault.totalSupply();
        accumulatedPerShare = accumulated.mulDivDown(10 ** decimalsBoring, currentTotalSupply);
    }

    function _totalLiquidity(uint256 /*exchangeRate*/ ) internal view virtual returns (uint256 /*accumulated*/ ) {
        revert FluxManager__NotImplemented();
    }

    function _convertLiquidityToToken(uint256, /*exchangeRate*/ uint128, /*liquidity*/ bool /*token0Or1*/ )
        internal
        virtual
        returns (uint256 /*amount*/ )
    {
        revert FluxManager__NotImplemented();
    }

    function _resetHighWatermark() internal {
        (uint256 accumulatedPerShare, uint256 currentTotalSupply) = _getAccumulatedPerShareBasedOffMetric();

        highWatermark = SafeCast.toUint128(accumulatedPerShare);
        totalSupplyLastReview = SafeCast.toUint128(currentTotalSupply);
        lastPerformanceReview = uint64(block.timestamp);
    }

    function _claimFees(bool token0Or1) internal {
        uint256 pending = pendingFee;
        if (pending > 0) {
            uint256 exchangeRate = datum.getDatumInDecimals(decimals1);
            address token;
            uint256 amount;
            if (token0Or1) {
                token = address(token0);
                if (performanceMetric == PerformanceMetric.TOKEN0) {
                    amount = pending;
                } else if (performanceMetric == PerformanceMetric.TOKEN1) {
                    amount = pending.mulDivDown(10 ** decimals0, exchangeRate);
                } else if (performanceMetric == PerformanceMetric.LIQUIDITY) {
                    amount = _convertLiquidityToToken(exchangeRate, uint128(pending), token0Or1);
                }
            } else {
                token = address(token1);
                if (performanceMetric == PerformanceMetric.TOKEN0) {
                    amount = pending.mulDivDown(exchangeRate, 10 ** decimals0);
                } else if (performanceMetric == PerformanceMetric.TOKEN1) {
                    amount = pending;
                } else if (performanceMetric == PerformanceMetric.LIQUIDITY) {
                    amount = _convertLiquidityToToken(exchangeRate, uint128(pending), token0Or1);
                }
            }

            pendingFee = 0;
            if (address(token) == address(0)) {
                // Wrap it.
                boringVault.manage(nativeWrapper, abi.encodeWithSelector(WETH.deposit.selector), amount);
                // Transfer it.
                boringVault.manage(nativeWrapper, abi.encodeWithSelector(ERC20.transfer.selector, payout, amount), 0);
            } else {
                // Transfer it.
                boringVault.manage(token, abi.encodeWithSelector(ERC20.transfer.selector, payout, amount), 0);
            }
        }
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
