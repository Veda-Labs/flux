// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {BoringVault} from "src/BoringVault.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {IDatum} from "src/interfaces/IDatum.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WETH} from "@solmate/src/tokens/WETH.sol";

/// @notice Manager used for Flux Boring Vaults
///
/// @dev
/// This contract is responsible for gating calls the boring vault can make
/// and for abstratcing the total assets calculation down to a flux function.
abstract contract FluxManager is Auth {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint16 internal constant BPS_SCALE = 10_000;
    uint16 internal constant MIN_DATUM_BOUND = 0.9e4;
    uint16 internal constant MAX_DATUM_BOUND = 1.1e4;
    uint16 internal constant MAX_PERFORMANCE_FEE = 0.3e4;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Used to pause calls to `FluxManager`.
     */
    bool public isPaused;

    IDatum public datum;
    uint16 public datumLowerBound;
    uint16 public datumUpperBound;

    uint16 public performanceFee;
    address public payout;
    uint128 public pendingFee;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error FluxManager__Paused();
    error FluxManager__InvalidExchangeRate(uint256 provided);
    error FluxManager__WrongMetric();
    error FluxManager__NotImplemented();
    error FluxManager__TooSoon();
    error FluxManager__BadDatumBounds();
    error FluxManager__BadPerformanceFee();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused();
    event Unpaused();
    event DatumConfigured();
    event PerformanceFeeSet();

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

    BoringVault public immutable boringVault;
    ERC20 public immutable token0;
    ERC20 public immutable token1;
    uint8 internal immutable decimals0;
    uint8 internal immutable decimals1;
    uint8 internal immutable decimalsBoring;
    bool public immutable baseIn0Or1; // Only used for initial share price when zero shares outstanding, and for totalAssets check
    bool public immutable token0IsNative;
    address public immutable nativeWrapper;

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
        token0IsNative = _token0 == address(0);
        nativeWrapper = _nativeWrapper;
        datum = IDatum(_datum);

        if (
            _datumLowerBound > BPS_SCALE || _datumLowerBound < MIN_DATUM_BOUND || _datumUpperBound < BPS_SCALE
                || _datumUpperBound > MAX_DATUM_BOUND
        ) revert FluxManager__BadDatumBounds();
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

    function claimFees(bool token0Or1) external requiresAuth {
        _claimFees(token0Or1);
    }

    function setPayout(address newPayout) external requiresAuth {
        payout = newPayout;
    }

    function setPerformanceFee(uint16 fee) external requiresAuth {
        if (fee > MAX_PERFORMANCE_FEE) revert FluxManager__BadPerformanceFee();
        performanceFee = fee;
        emit PerformanceFeeSet();
    }

    function configureDatum(address _datum, uint16 _datumLowerBound, uint16 _datumUpperBound) external requiresAuth {
        datum = IDatum(_datum);
        if (
            _datumLowerBound > BPS_SCALE || _datumLowerBound < MIN_DATUM_BOUND || _datumUpperBound < BPS_SCALE
                || _datumUpperBound > MAX_DATUM_BOUND
        ) revert FluxManager__BadDatumBounds();
        datumLowerBound = _datumLowerBound;
        datumUpperBound = _datumUpperBound;

        emit DatumConfigured();
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
            uint256 converted = token1Assets.mulDivDown(10 ** decimals0, exchangeRate);
            assets = token0Assets + converted;
        } else {
            // Return totalAssets in token1
            uint256 converted = token0Assets.mulDivDown(exchangeRate, 10 ** decimals0);
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
                return exchangeRate;
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FLUX INTERNAL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _claimFees(bool token0Or1) internal {
        uint256 pending = pendingFee;
        if (pending > 0) {
            address token = token0Or1 ? address(token0) : address(token1);
            pendingFee = 0;
            if (address(token) == address(0)) {
                // Transfer it.
                boringVault.manage(nativeWrapper, abi.encodeWithSelector(ERC20.transfer.selector, payout, pending), 0);
            } else {
                // Transfer it.
                boringVault.manage(token, abi.encodeWithSelector(ERC20.transfer.selector, payout, pending), 0);
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ABSTRACT FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _totalAssets(uint256 exchangeRate)
        internal
        view
        virtual
        returns (uint256 token0Assets, uint256 token1Assets);
}
