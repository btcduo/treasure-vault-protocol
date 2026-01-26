// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// OpenZeppelin
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SplitSig} from "./libraries/SplitSig.sol";
// Errors
import {VaultErrors} from "./libraries/Errors.sol";

/// @title Vault
/// @notice Template implementation for EIP-1167 clone instances.
/**
 * @dev Safe summaries:
 * Disables the initializers in the constructor, guaranteeing this context cannot be initialize by any address.
 * Adds `nonReentrant` to Reentrantable entry points( _deposit() / withdraw() / redeem() )
 * Each clone instance can invokes `initialize` function at most once.
 * ERC20-only, fee-on-transfer / rebasing tokens unsupported.
 * @dev Fee-on-transfer tokens are partially handled on _deposit(credits `received`), discouraged though.
 * @dev Uses ERC2771Context for meta-txs via a trusted forwarder.
 * @dev Uses SafeERC20 for compatibility with non-standard ERC20s (e.g.: USDT does not return boolean values).
 * @dev Uses ERC20Permit for allowance via signature, enabling approval and deposit in a single transaction.
 */
contract Vault is Initializable, ERC20Permit {
    using SafeERC20 for IERC20;

    IERC20 public asset;

    address internal immutable template;

    /// @notice Non-reentrant lock.
    uint256 private _status;

    /// @notice MultiSig governor.
    address public governor;

    address public trustedForwarder;

    uint256 public totalUnderlying;

    event Deposit(address indexed funder, address to, uint256 amount, uint256 shares);
    event Withdrawn(address indexed funder, address to, uint256 shares, uint256 amount);
    event Redeem(address indexed funder, address to, uint256 shares, uint256 amount);
    event Skim(address treasury, uint256 surplus);
    event Sync(uint256 totalValue, uint256 actualValue);

    constructor() ERC20("", "") ERC20Permit("Vault Share") {
        _disableInitializers();
        template = address(this);
    }

    /// A modifier that enforces a function is invoked by registered governor.
    modifier onlyGovernor() {
        if (msg.sender != governor) {
            revert VaultErrors.NotGovernor();
        }
        _;
    }

    modifier nonReentrant() {
        if (_status == 2) {
            revert VaultErrors.Reentrant();
        }
        _status = 2;
        _;
        _status = 1;
    }

    /**
     * @notice Initializes clone state(must be called once per clone)
     * @param _asset The underlying asset token used to mint shares(clone token).
     * @param _governor The MultiSig governance.
     * @param _fwd The forwarder address.
     * @dev Safe summary: settles the _status(non-reentrant lock) to `1`.
     */
    function initialize(address _asset, address _governor, address _fwd) external initializer {
        _initAddrCheck(_asset, _governor, _fwd);

        asset = IERC20(_asset);
        governor = _governor;
        trustedForwarder = _fwd;

        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNALS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Transfers `amount` from _msgSender() to the clone, and mints the `shares` to `to`.
     * @param to The receiver of shares.
     * @param amount The value of the asset token.
     * @return shares converted amount of the clone's token.
     */
    function deposit(address to, uint256 amount) external returns (uint256 shares) {
        shares = _deposit(_msgSender(), to, amount);
    }

    /**
     * @notice Transfers `amount` from the clone to `to`, and burns the `shares` of _msgSender().
     * @param to The receiver of shares.
     * @param amount The value of the asset token.
     * @return shares converted amount of the clone's token.
     * @dev Safe summary:
     * Calculates the amount to shares using CEIL rounding.
     * E.G.: (withdraw: 20) * (total shares: 11) / (total underlying: 34) ≈ 6.47(burn shares = 7), instead of user keep the 0.47 of the shares.
     */
    function withdraw(address to, uint256 amount) external nonReentrant returns (uint256 shares) {
        _notZeroAddr(to);
        _notZeroAmt(amount);

        uint256 _totalUnderlying = totalUnderlying;
        uint256 _totalSupply = totalSupply();
        if (amount > _totalUnderlying) {
            revert VaultErrors.InsufficientUnderlying();
        }

        shares = _convertToSharesCeil(amount, _totalUnderlying, _totalSupply, Math.Rounding.Ceil);
        _notZeroShares(shares);
        address realSender = _msgSender();
        if (shares > balanceOf(realSender)) {
            revert VaultErrors.InsufficientShares();
        }

        totalUnderlying = _totalUnderlying - amount;

        asset.safeTransfer(to, amount);

        _burn(realSender, shares);

        emit Withdrawn(realSender, to, shares, amount);
    }

    /**
     * @notice Transfers `amount` from the clone to `to`, and burns the `shares` of _msgSender().
     * @param to The receiver of shares.
     * @param shares The value of the clone's token.
     * @return amount converted amount of the asset token.
     * @dev Safe summary:
     * Calculates the shares to amount using FLOOR rounding.
     * E.G.: (redeem: 3) * (total underlying: 47) / (total shares: 13) ≈ 10.84(byrn shares = 10).
     */
    function redeem(address to, uint256 shares) external nonReentrant returns (uint256 amount) {
        _notZeroAddr(to);
        _notZeroShares(shares);
        address realSender = _msgSender();
        if (shares > balanceOf(realSender)) {
            revert VaultErrors.InsufficientShares();
        }

        uint256 _totalUnderlying = totalUnderlying;
        uint256 _totalSupply = totalSupply();

        amount = _convertToAssetsFloor(shares, _totalUnderlying, _totalSupply, Math.Rounding.Floor);
        _notZeroAmt(amount);
        if (amount > _totalUnderlying) {
            revert VaultErrors.InsufficientUnderlying();
        }

        totalUnderlying = _totalUnderlying - amount;

        asset.safeTransfer(to, amount);

        _burn(realSender, shares);

        emit Redeem(realSender, to, shares, amount);
    }

    /**
     * @notice Transfers `amount` from _msgSender() to the clone, and mints the `shares` to `to`.
     * @param to The receiver of shares.
     * @param amount The value of the asset token.
     * @return shares converted amount of the clone's token.
     * @dev Using ERC20Permit.permit() to set allowance via user's signature, then deposits.
     * @dev EOA only, due to the ERC20Permit does not support ERC1271.
     */
    function depositWithPermit(address to, uint256 amount, uint256 value, uint256 deadline, bytes calldata sig)
        external
        returns (uint256 shares)
    {
        _notZeroAddr(to);
        _notZeroAmt(amount);
        if (amount > value) {
            revert VaultErrors.InsufficientValue();
        }

        address realSender = _msgSender();
        if (realSender.code.length > 0) {
            revert VaultErrors.PermitEOAOnly();
        }

        (uint8 v, bytes32 r, bytes32 s) = SplitSig.split(sig);
        IERC20Permit(address(asset)).permit(realSender, address(this), value, deadline, v, r, s);

        shares = _deposit(realSender, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ONLY GOVERNOR
    //////////////////////////////////////////////////////////////*/
    /// @notice Transfers the extra amount of `totalUnderlying` to `to`.
    /// @dev Reverts when `totalUnderlying` greater than the actual values.
    function skimAssetSurplus(address to) external onlyGovernor {
        _notZeroAddr(to);
        uint256 managed = totalUnderlying;
        uint256 actual = asset.balanceOf(address(this));
        if (managed > actual) {
            revert VaultErrors.BadLedger(managed, actual);
        }
        uint256 surplus = actual - managed;
        if (surplus == 0) {
            return;
        } else {
            asset.safeTransfer(to, surplus);
        }

        emit Skim(to, surplus);
    }

    /// @notice Syncs `totalUnderlying` to the actual values.
    /// @dev Reverts when `totalUnderlying` greater than the actual values.
    function sync() external onlyGovernor {
        uint256 managed = totalUnderlying;
        uint256 actual = asset.balanceOf(address(this));
        if (managed > actual) {
            revert VaultErrors.BadLedger(managed, actual);
        }
        if (actual > managed) {
            totalUnderlying = actual;
        }

        emit Sync(managed, actual);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Safe summaries:
     * Calculates the amount to shares using FLOOR rounding.
     * E.G.: (deposit: 2) * (total underlying: 25) / (total shares: 7) ≈ 7.14(mint shares = 7).
     * Updates the ledger based on the actually received amount.
     */
    function _deposit(address realSender, address to, uint256 amount) internal nonReentrant returns (uint256 shares) {
        _notZeroAddr(to);
        _notZeroAmt(amount);

        uint256 balBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(realSender, address(this), amount);
        uint256 balAfter = asset.balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        if (received == 0) {
            revert VaultErrors.ZeroReceived();
        }

        uint256 _totalUnderlying = totalUnderlying;
        uint256 _totalSupply = totalSupply();

        shares = _convertToSharesFloor(received, _totalUnderlying, _totalSupply, Math.Rounding.Floor);
        _notZeroShares(shares);

        totalUnderlying = _totalUnderlying + received;
        _mint(to, shares);

        emit Deposit(realSender, to, received, shares);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _convertToSharesFloor(uint256 amount, uint256 _totalUnderlying, uint256 _totalSupply, Math.Rounding _floor)
        internal
        pure
        returns (uint256 shares)
    {
        if (_totalSupply == 0) {
            return shares = amount;
        }
        _notZeroAmt(_totalUnderlying);

        shares = Math.mulDiv(amount, _totalSupply, _totalUnderlying, _floor);
    }

    function _convertToAssetsFloor(uint256 shares, uint256 _totalUnderlying, uint256 _totalSupply, Math.Rounding _floor)
        internal
        pure
        returns (uint256 assets)
    {
        if (_totalSupply == 0 || _totalUnderlying == 0) {
            return 0;
        }

        assets = Math.mulDiv(shares, _totalUnderlying, _totalSupply, _floor);
    }

    function _convertToSharesCeil(uint256 amount, uint256 _totalUnderlying, uint256 _totalSupply, Math.Rounding _ceil)
        internal
        pure
        returns (uint256 shares)
    {
        if (_totalSupply == 0 || _totalUnderlying == 0) {
            return 0;
        }

        shares = Math.mulDiv(amount, _totalSupply, _totalUnderlying, _ceil);
    }

    /// @notice Overrides OZ's ERC2771Context._msgSender().
    function _msgSender() internal view override returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /// @notice Overrides OZ's ERC2771Context._msgData().
    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return msg.data;
    }

    function isTrustedForwarder(address fwd) public view returns (bool) {
        return fwd == trustedForwarder;
    }

    /*//////////////////////////////////////////////////////////////
                            VERIFICATIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Validates input addresses:
     * Must be non-zero.
     * Must be contracts.
     * Must be distinct from each other.
     * Must not equal the template address.
     */
    function _initAddrCheck(address _asset, address _governor, address _fwd) private view {
        if (_asset == address(0)) {
            revert VaultErrors.ZeroAssetAddr();
        }
        if (_asset.code.length == 0) {
            revert VaultErrors.InvalidAssetAddr();
        }
        if (_asset == _governor || _asset == _fwd || _governor == _fwd) {
            revert VaultErrors.UnsafeParams();
        }
        if (_asset == template || _governor == template || _fwd == template) {
            revert VaultErrors.InvalidParams();
        }
        if (_governor == address(0)) {
            revert VaultErrors.ZeroOwnerAddr();
        }
        if (_governor.code.length == 0) {
            revert VaultErrors.InvalidOwnerAddr();
        }
        if (_fwd == address(0)) {
            revert VaultErrors.ZeroFwdAddr();
        }
        if (_fwd.code.length == 0) {
            revert VaultErrors.InvalidFwdAddr();
        }
    }

    function _notZeroAddr(address addr) private pure {
        if (addr == address(0)) {
            revert VaultErrors.ZeroAddr();
        }
    }

    function _notZeroAmt(uint256 amount) private pure {
        if (amount == 0) {
            revert VaultErrors.ZeroAmount();
        }
    }

    function _notZeroShares(uint256 shares) private pure {
        if (shares == 0) {
            revert VaultErrors.ZeroShares();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/
    function previewDeposit(uint256 assets_) external view returns (uint256) {
        return _convertToSharesFloor(assets_, totalUnderlying, totalSupply(), Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets_) external view returns (uint256) {
        return _convertToSharesCeil(assets_, totalUnderlying, totalSupply(), Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares_) external view returns (uint256) {
        return _convertToAssetsFloor(shares_, totalUnderlying, totalSupply(), Math.Rounding.Floor);
    }

    /// @notice Overrides OZ's ERC20.name() with the permanent string.
    function name() public pure override returns (string memory) {
        return "Vault Share";
    }

    /// @notice Overrides OZ's ERC20.symbol() with the permanent string.
    function symbol() public pure override returns (string memory) {
        return "vSHARE";
    }
}
