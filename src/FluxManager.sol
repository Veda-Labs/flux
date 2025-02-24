// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {BoringVault} from "src/BoringVault.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/src/tokens/ERC20.sol";

/// @notice Manager used for Flux Boring Vaults
///
/// @dev
/// This contract is responsible for gating calls the boring vault can make
/// and for abstratcing the total assets calculation down to a flux function.
abstract contract FluxManager is Auth {
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STATE                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Used to pause calls to `FluxManager`.
     */
    bool public isPaused;
    uint8 public exchangeRateDecimals;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error FluxManager__Paused();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused();
    event Unpaused();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       IMMUTABLES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    BoringVault internal immutable boringVault;
    ERC20 public immutable token0;
    ERC20 public immutable token1;
    uint8 internal immutable decimals0;
    uint8 internal immutable decimals1;
    uint8 internal immutable decimalsBoring;

    constructor(address _owner, address _boringVault, address _token0, address _token1)
        Auth(_owner, Authority(address(0)))
    {
        boringVault = BoringVault(payable(_boringVault));
        token0 = ERC20(_token0);
        token1 = ERC20(_token1);
        decimals0 = token0.decimals();
        decimals1 = token1.decimals();
        decimalsBoring = boringVault.decimals();
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       FLUX VIEW                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function totalAssets(uint256 exchangeRate, bool quoteIn0Or1) public view returns (uint256 assets) {
        (uint256 token0Assets, uint256 token1Assets) = _totalAssets(exchangeRate);
        if (quoteIn0Or1) {
            // Return totalAssets in token0
            uint256 converted = token1Assets * (10 ** decimals0);
            converted = converted.mulDivDown(10 ** exchangeRateDecimals, exchangeRate);
            converted /= 10 ** decimals1;
            assets = token0Assets + converted;
        } else {
            // Return totalASsets in token1
            uint256 converted = token0Assets * (10 ** decimals1);
            converted = converted.mulDivDown(exchangeRate, 10 ** exchangeRateDecimals);
            converted /= 10 ** decimals0;
            assets = token1Assets + converted;
        }
    }

    function totalAssets(uint256 exchangeRate) external view returns (uint256 token0Assets, uint256 token1Assets) {
        return _totalAssets(exchangeRate);
    }

    function getRate(uint256 exchangeRate, bool quoteIn0Or1) public view returns (uint256) {
        uint256 ts = boringVault.totalSupply();
        uint256 ta = totalAssets(exchangeRate, quoteIn0Or1);
        return ta.mulDivDown(10 ** decimalsBoring, ts);
    }

    function getRateSafe(uint256 exchangeRate, bool quoteIn0Or1) external view returns (uint256) {
        if (isPaused) revert FluxManager__Paused();
        return getRate(exchangeRate, quoteIn0Or1);
    }

    function getRate(uint256 exchangeRate) public view returns (uint256 token0PerShare, uint256 token1PerShare) {
        uint256 ts = boringVault.totalSupply();
        (uint256 ta0, uint256 ta1) = _totalAssets(exchangeRate);
        token0PerShare = ta0.mulDivDown(10 ** decimalsBoring, ts);
        token1PerShare = ta1.mulDivDown(10 ** decimalsBoring, ts);
    }

    function getRateSafe(uint256 exchangeRate) external view returns (uint256 token0PerShare, uint256 token1PerShare) {
        if (isPaused) revert FluxManager__Paused();
        return getRate(exchangeRate);
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
