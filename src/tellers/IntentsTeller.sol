// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "@solmate/src/tokens/ERC20.sol";
import {BoringVault} from "src/BoringVault.sol";
import {FluxManager} from "src/FluxManager.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "@solmate/src/utils/SafeTransferLib.sol";
import {BeforeTransferHook} from "src/interfaces/BeforeTransferHook.sol";
import {Auth, Authority} from "@solmate/src/auth/Auth.sol";
import {ReentrancyGuard} from "@solmate/src/utils/ReentrancyGuard.sol";
import {IPausable} from "src/interfaces/IPausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract IntentsTeller is Auth, BeforeTransferHook, ReentrancyGuard, IPausable {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // ========================================= STRUCTS =========================================
    /**
     * @param allowDeposits bool indicating whether or not deposits are allowed for this asset.
     * @param allowWithdraws bool indicating whether or not withdraws are allowed for this asset.
     * @param sharePremium uint16 indicating the premium to apply to the shares minted.
     *        where 40 represents a 40bps reduction in shares minted using this asset.
     */
    struct Asset {
        bool allowDeposits;
        bool allowWithdraws;
        uint16 sharePremium;
    }

    struct ActionData {
        bool isWithdrawal;
        address user;
        address to;
        ERC20 asset;
        uint256 amountIn;
        uint256 minimumOut;
        uint256 rate;
        uint256 deadline;
        bytes sig;
    }

    // ========================================= CONSTANTS =========================================

    /**
     * @notice The maximum possible share lock period.
     */
    uint256 internal constant MAX_SHARE_LOCK_PERIOD = 3 days;

    /**
     * @notice The maximum possible share premium that can be set using `updateAssetData`.
     * @dev 1,000 or 10%
     */
    uint16 internal constant MAX_SHARE_PREMIUM = 1_000;

    // ========================================= STATE =========================================

    /**
     * @notice The Flux Manager associated with this Teller and BoringVault.
     */
    FluxManager public fluxManager;

    /**
     * @notice The token0 associated with fluxManager
     */
    ERC20 public immutable token0;

    /**
     * @notice The token1 associated with fluxManager
     */
    ERC20 public immutable token1;

    /**
     * @notice Mapping ERC20s to their assetData.
     */
    mapping(ERC20 => Asset) public assetData;

    /**
     * @notice The deposit nonce used to map to a deposit hash.
     */
    uint96 public depositNonce;

    /**
     * @notice After deposits, shares are locked to the msg.sender's address
     *         for `shareLockPeriod`.
     * @dev During this time all trasnfers from msg.sender will revert, and
     *      deposits are refundable.
     */
    uint64 public shareLockPeriod;

    /**
     * @notice The maximum length of time after block.timestamp that a signed rate can be valid.
     */
    uint64 public maxDeadlinePeriod;

    /**
     * @notice Used to pause deposits and withdrawals.
     */
    bool public isPaused;

    /**
     * @dev Maps deposit nonce to keccak256(address receiver, address depositAsset, uint256 depositAmount, uint256 shareAmount, uint256 timestamp, uint256 shareLockPeriod).
     */
    mapping(uint256 => bytes32) public publicDepositHistory;

    /**
     * @notice Maps user address to the time their shares will be unlocked.
     */
    mapping(address => uint256) public shareUnlockTime;

    /**
     * @notice Mapping `from` address to a bool to deny them from transferring shares.
     */
    mapping(address => bool) public fromDenyList;

    /**
     * @notice Mapping `to` address to a bool to deny them from receiving shares.
     */
    mapping(address => bool) public toDenyList;

    /**
     * @notice Mapping `opeartor` address to a bool to deny them from calling `transfer` or `transferFrom`.
     */
    mapping(address => bool) public operatorDenyList;

    /**
     * @notice Mapping ethSignedMessageHash to a bool to deny them from using the same signature twice.
     */
    mapping(bytes32 => bool) public usedSignatures;

    //============================== ERRORS ===============================

    error IntentsTeller__ShareLockPeriodTooLong();
    error IntentsTeller__SharesAreLocked();
    error IntentsTeller__SharesAreUnLocked();
    error IntentsTeller__BadDepositHash();
    error IntentsTeller__AssetNotSupported();
    error IntentsTeller__ZeroAssets();
    error IntentsTeller__MinimumMintNotMet();
    error IntentsTeller__MinimumAssetsNotMet();
    error IntentsTeller__ZeroShares();
    error IntentsTeller__DualDeposit();
    error IntentsTeller__Paused();
    error IntentsTeller__TransferDenied(address from, address to, address operator);
    error IntentsTeller__SharePremiumTooLarge();
    error IntentsTeller__CannotDepositNative();
    error IntentsTeller__InvalidSignature();
    error IntentsTeller__DuplicateSignature();
    error IntentsTeller__SignatureExpired();
    error IntentsTeller__DeadlineOutsideMaxPeriod();
    error IntentsTeller__ActionMismatch();
    error IntentsTeller__OnlyPoolTokens();

    //============================== EVENTS ===============================

    event Paused();
    event Unpaused();
    event AssetDataUpdated(address indexed asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium);
    event Deposit(
        uint256 indexed nonce,
        address indexed receiver,
        address indexed depositAsset,
        uint256 depositAmount,
        uint256 shareAmount,
        uint256 depositTimestamp,
        uint256 shareLockPeriodAtTimeOfDeposit
    );
    event BulkDeposit(address indexed asset, uint256 depositAmount);
    event Withdraw(address indexed asset, uint256 shareAmount);
    event DepositRefunded(uint256 indexed nonce, bytes32 depositHash, address indexed user);
    event DenyFrom(address indexed user);
    event DenyTo(address indexed user);
    event DenyOperator(address indexed user);
    event AllowFrom(address indexed user);
    event AllowTo(address indexed user);
    event AllowOperator(address indexed user);

    event RateSignerSet(address indexed rateSigner);

    //============================== IMMUTABLES ===============================

    /**
     * @notice The BoringVault this contract is working with.
     */
    BoringVault public immutable vault;

    /**
     * @notice One share of the BoringVault.
     */
    uint256 internal immutable ONE_SHARE;

    constructor(address _owner, address _vault, address _fluxManager, uint64 _maxDeadlinePeriod)
        Auth(_owner, Authority(address(0)))
    {
        vault = BoringVault(payable(_vault));
        ONE_SHARE = 10 ** vault.decimals();
        fluxManager = FluxManager(_fluxManager);
        token0 = fluxManager.token0();
        token1 = fluxManager.token1();
        maxDeadlinePeriod = uint64(_maxDeadlinePeriod);
    }

    // ========================================= ADMIN FUNCTIONS =========================================

    /**
     * @notice Pause this contract, which prevents future calls to `deposit` and `bulkWithdraw`.
     * @dev Callable by MULTISIG_ROLE.
     */
    function pause() external requiresAuth {
        isPaused = true;
        emit Paused();
    }

    /**
     * @notice Unpause this contract, which allows future calls to `deposit` and `bulkWithdraw`.
     * @dev Callable by MULTISIG_ROLE.
     */
    function unpause() external requiresAuth {
        isPaused = false;
        emit Unpaused();
    }

    /**
     * @notice Updates the asset data for a given asset.
     * @dev The accountant must also support pricing this asset, else the `deposit` call will revert.
     * @dev Callable by OWNER_ROLE.
     */
    function updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium)
        external
        requiresAuth
    {
        if (sharePremium > MAX_SHARE_PREMIUM) {
            revert IntentsTeller__SharePremiumTooLarge();
        }
        if (asset != token0 && asset != token1) {
            revert IntentsTeller__OnlyPoolTokens();
        }
        assetData[asset] = Asset(allowDeposits, allowWithdraws, sharePremium);
        emit AssetDataUpdated(address(asset), allowDeposits, allowWithdraws, sharePremium);
    }

    /**
     * @notice Sets the share lock period.
     * @dev This not only locks shares to the user address, but also serves as the pending deposit period, where deposits can be reverted.
     * @dev If a new shorter share lock period is set, users with pending share locks could make a new deposit to receive 1 wei shares,
     *      and have their shares unlock sooner than their original deposit allows. This state would allow for the user deposit to be refunded,
     *      but only if they have not transferred their shares out of there wallet. This is an accepted limitation, and should be known when decreasing
     *      the share lock period.
     * @dev Callable by OWNER_ROLE.
     */
    function setShareLockPeriod(uint64 _shareLockPeriod) external requiresAuth {
        if (_shareLockPeriod > MAX_SHARE_LOCK_PERIOD) {
            revert IntentsTeller__ShareLockPeriodTooLong();
        }
        shareLockPeriod = _shareLockPeriod;
    }

    /**
     * @notice Sets the maximum deadline period for signed messages.
     * @dev Callable by OWNER_ROLE.
     */
    function setMaxDeadlinePeriod(uint64 _maxDeadlinePeriod) external requiresAuth {
        maxDeadlinePeriod = _maxDeadlinePeriod;
    }

    /**
     * @notice Deny a user from transferring or receiving shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function denyAll(address user) external requiresAuth {
        fromDenyList[user] = true;
        toDenyList[user] = true;
        operatorDenyList[user] = true;
        emit DenyFrom(user);
        emit DenyTo(user);
        emit DenyOperator(user);
    }

    /**
     * @notice Allow a user to transfer or receive shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function allowAll(address user) external requiresAuth {
        fromDenyList[user] = false;
        toDenyList[user] = false;
        operatorDenyList[user] = false;
        emit AllowFrom(user);
        emit AllowTo(user);
        emit AllowOperator(user);
    }

    /**
     * @notice Deny a user from transferring shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function denyFrom(address user) external requiresAuth {
        fromDenyList[user] = true;
        emit DenyFrom(user);
    }

    /**
     * @notice Allow a user to transfer shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function allowFrom(address user) external requiresAuth {
        fromDenyList[user] = false;
        emit AllowFrom(user);
    }

    /**
     * @notice Deny a user from receiving shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function denyTo(address user) external requiresAuth {
        toDenyList[user] = true;
        emit DenyTo(user);
    }

    /**
     * @notice Allow a user to receive shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function allowTo(address user) external requiresAuth {
        toDenyList[user] = false;
        emit AllowTo(user);
    }

    /**
     * @notice Deny an operator from transferring shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function denyOperator(address user) external requiresAuth {
        operatorDenyList[user] = true;
        emit DenyOperator(user);
    }

    /**
     * @notice Allow an operator to transfer shares.
     * @dev Callable by OWNER_ROLE, and DENIER_ROLE.
     */
    function allowOperator(address user) external requiresAuth {
        operatorDenyList[user] = false;
        emit AllowOperator(user);
    }

    // ========================================= BeforeTransferHook FUNCTIONS =========================================

    /**
     * @notice Implement beforeTransfer hook to check if shares are locked, or if `from`, `to`, or `operator` are on the deny list.
     * @notice If share lock period is set to zero, then users will be able to mint and transfer in the same tx.
     *         if this behavior is not desired then a share lock period of >=1 should be used.
     */
    function beforeTransfer(address from, address to, address operator) public view virtual {
        if (fromDenyList[from] || toDenyList[to] || operatorDenyList[operator]) {
            revert IntentsTeller__TransferDenied(from, to, operator);
        }
        if (shareUnlockTime[from] > block.timestamp) {
            revert IntentsTeller__SharesAreLocked();
        }
    }

    // ========================================= REVERT DEPOSIT FUNCTIONS =========================================

    /**
     * @notice Allows DEPOSIT_REFUNDER_ROLE to revert a pending deposit.
     * @dev Once a deposit share lock period has passed, it can no longer be reverted.
     * @dev It is possible the admin does not setup the BoringVault to call the transfer hook,
     *      but this contract can still be saving share lock state. In the event this happens
     *      deposits are still refundable if the user has not transferred their shares.
     *      But there is no guarantee that the user has not transferred their shares.
     * @dev Callable by STRATEGIST_MULTISIG_ROLE.
     */
    function refundDeposit(
        uint256 nonce,
        address receiver,
        address depositAsset,
        uint256 depositAmount,
        uint256 shareAmount,
        uint256 depositTimestamp,
        uint256 shareLockUpPeriodAtTimeOfDeposit
    ) external requiresAuth {
        if ((block.timestamp - depositTimestamp) >= shareLockUpPeriodAtTimeOfDeposit) {
            // Shares are already unlocked, so we can not revert deposit.
            revert IntentsTeller__SharesAreUnLocked();
        }
        bytes32 depositHash = keccak256(
            abi.encode(
                receiver, depositAsset, depositAmount, shareAmount, depositTimestamp, shareLockUpPeriodAtTimeOfDeposit
            )
        );
        if (publicDepositHistory[nonce] != depositHash) {
            revert IntentsTeller__BadDepositHash();
        }

        // Delete hash to prevent refund gas.
        delete publicDepositHistory[nonce];

        // Burn shares and refund assets to receiver.
        vault.exit(receiver, ERC20(depositAsset), depositAmount, receiver, shareAmount);

        emit DepositRefunded(nonce, depositHash, receiver);
    }

    // ========================================= SOLVER FUNCTIONS =========================================

    /**
     * @notice Allows users to deposit into the BoringVault, if this contract is not paused.
     * @dev Callable by SOLVER_ROLE.
     * @dev Does NOT support native deposits.
     */
    function deposit(ActionData memory depositData, bool enforceShareLock) external requiresAuth nonReentrant returns (uint256 shares) {
        if (isPaused) revert IntentsTeller__Paused();

        shares = _erc20Deposit(depositData, enforceShareLock);
    }

    /**
     * @notice Allows off ramp role to withdraw from this contract.
     * @dev Callable by SOLVER_ROLE.
     * @dev Does NOT support native withdrawals.
     */
    function withdraw(ActionData memory withdrawData) external requiresAuth returns (uint256 assetsOut) {
        if (isPaused) revert IntentsTeller__Paused();

        assetsOut = _erc20Withdraw(withdrawData);
    }

    function bulkActions(ActionData[] memory actionData, bool[] memory enforceShareLock) external requiresAuth nonReentrant {
        for (uint256 i = 0; i < actionData.length; i++) {
            if (actionData[i].isWithdrawal) {
                _erc20Withdraw(actionData[i]);
            } else {
                _erc20Deposit(actionData[i], enforceShareLock[i]);
            }
        }
    }

    // =========================================== USER FUNCTIONS =========================================

    /**
     * @notice Allows users to cancel a pending signature.
     * @dev Callable by the user who signed the message.
     */
    function cancelSignature(ActionData memory actionData) external requiresAuth {
        // revert if the msg.sender is not the signer so that users can only cancel their own signatures
        if (actionData.user != msg.sender) {
            revert IntentsTeller__InvalidSignature();
        }
        _verifySignedMessage(actionData);
    }

    // ========================================= INTERNAL HELPER FUNCTIONS =========================================

    /**
     * @notice Implements a common ERC20 deposit into BoringVault.
     */
    function _erc20Deposit(ActionData memory depositData, bool enforceShareLock) internal returns (uint256 shares) {
        if (depositData.amountIn == 0) {
            revert IntentsTeller__ZeroAssets();
        }
        
        _verifySignedMessage(depositData);

        fluxManager.refreshInternalFluxAccounting();

        shares = depositData.amountIn.mulDivDown(ONE_SHARE, fluxManager.getRateSafe(depositData.rate, depositData.asset == token0)); // TODO check rate direction

        Asset memory asset = _beforeDeposit(depositData.asset);
        shares = asset.sharePremium > 0 ? shares.mulDivDown(1e4 - asset.sharePremium, 1e4) : shares;
        if (shares < depositData.minimumOut) {
            revert IntentsTeller__MinimumMintNotMet();
        }
        
        beforeTransfer(address(0), depositData.to, msg.sender); // TODO: check these are the correct addrs
        vault.enter(depositData.user, depositData.asset, depositData.amountIn, depositData.to, shares);
        
        if (enforceShareLock) {
            _afterPublicDeposit(depositData.user, depositData.asset, depositData.amountIn, shares, shareLockPeriod);
        } else {
            emit BulkDeposit(address(depositData.asset), depositData.amountIn);
        }
    }

    function _erc20Withdraw(ActionData memory withdrawData) internal returns (uint256 assetsOut) {
        Asset memory asset = assetData[withdrawData.asset];
        if (!asset.allowWithdraws) {
            revert IntentsTeller__AssetNotSupported();
        }

        if (withdrawData.amountIn == 0) revert IntentsTeller__ZeroShares();

        _verifySignedMessage(withdrawData);

        fluxManager.refreshInternalFluxAccounting();

        assetsOut = withdrawData.amountIn.mulDivDown(fluxManager.getRateSafe(withdrawData.rate, withdrawData.asset == token0), ONE_SHARE); // check rate direction

        if (assetsOut < withdrawData.minimumOut) {
            revert IntentsTeller__MinimumAssetsNotMet();
        }

        beforeTransfer(withdrawData.user, address(0), msg.sender); // TODO: check these are the correct addrs
        vault.exit(withdrawData.to, withdrawData.asset, assetsOut, withdrawData.user, withdrawData.amountIn);
        emit Withdraw(address(withdrawData.asset), withdrawData.amountIn);
    }

    /**
     * @notice Handle pre-deposit checks.
     */
    function _beforeDeposit(ERC20 depositAsset) internal view returns (Asset memory asset) {
        asset = assetData[depositAsset];
        if (!asset.allowDeposits) {
            revert IntentsTeller__AssetNotSupported();
        }
    }

    /**
     * @notice Handle share lock logic, and event.
     */
    function _afterPublicDeposit(
        address user,
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 shares,
        uint256 currentShareLockPeriod
    ) internal {
        // Increment then assign as its slightly more gas efficient.
        uint256 nonce = ++depositNonce;
        // Only set share unlock time and history if share lock period is greater than 0.
        if (currentShareLockPeriod > 0) {
            shareUnlockTime[user] = block.timestamp + currentShareLockPeriod;
            publicDepositHistory[nonce] = keccak256(
                abi.encode(user, depositAsset, depositAmount, shares, block.timestamp, currentShareLockPeriod)
            );
        }
        emit Deposit(nonce, user, address(depositAsset), depositAmount, shares, block.timestamp, currentShareLockPeriod);
    }

    function _verifySignedMessage(ActionData memory actionData) internal {
        // Recreate the signed message and verify the signature
        // Signature does not include rate as rate is specified by executor at execution time
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                address(this), // teller
                actionData.to, // receiver
                actionData.asset,
                actionData.isWithdrawal, // type
                actionData.amountIn, // amount
                actionData.minimumOut, // minimumOut
                actionData.deadline // deadline
            )
        );

        bytes32 signedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ECDSA.recover(signedMessageHash, actionData.sig);

        if (signer != actionData.user) {
            revert IntentsTeller__InvalidSignature();
        }
        if (block.timestamp > actionData.deadline) {
            revert IntentsTeller__SignatureExpired();
        }
        if (actionData.deadline > block.timestamp + maxDeadlinePeriod) {
            revert IntentsTeller__DeadlineOutsideMaxPeriod();
        }
        if (usedSignatures[signedMessageHash]) {
            revert IntentsTeller__DuplicateSignature();
        }

        usedSignatures[signedMessageHash] = true;
    }
}
