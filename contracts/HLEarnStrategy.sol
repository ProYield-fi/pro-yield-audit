// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HLConstants} from "./adapters/HLConstants.sol";
import {HLEarnLib} from "./adapters/HLEarnLib.sol";
import {ICoreWriter, ICoreDepositWallet} from "./adapters/HLInterfaces.sol";

/// @title HLEarnStrategy — HL Earn idle-cash sleeve
/// @notice Supplies idle USDC to HyperCore's native borrow/lend reserve via
/// CoreWriter action 15 (Supply/Withdraw only — a contract cannot borrow).
/// The contract is its own HyperCore actor: bridge EVM→Core spot, supply to
/// the reserve, withdraw back to spot, sendAsset back to EVM. Keeper pokes;
/// owner sets policy. See docs/HLEARN_SLEEVE_DESIGN.md.
///
/// HONEST ACCOUNTING (repo discipline):
/// - `corePrincipal6` = net USDC sent to Core for the sleeve (never yield).
/// - `supplyValue6`   = reserve supply value (0x811 read; refreshed by syncEarn).
/// - `coreSpot6`      = Core spot USDC (0x801 read; in transit / awaiting send).
/// - totalAssets()    = idle EVM + (supplyValue6 + coreSpot6) * coreScale.
/// - profit           = value above principal; only the part actually bridged
///   back (profitRealized) can be swept to the vault (mirrors DNCoreStrategy).
///
/// ASYNC (CoreWriter is fire-and-forget + delayed seconds): every action is
/// gated on the 0x810 read (`coreAccountRequired`) and the keeper verifies by
/// re-reading — never assume a read right after a send reflects the action.
/// `bufferBps` of assets stay idle on EVM for instant vault recalls;
/// larger recalls are unwound by the keeper first (DN discipline).
///
/// SIZE DISCIPLINE: EIP-170 (24,576 bytes) on HyperEVM — custom errors.
contract HLEarnStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);
    /// @dev Core wire scale for USDC: 1e8 wei per 1 USDC → 6-dec underlying ×100.
    uint64 internal constant WEI_PER_UNIT = 100;
    /// @notice Fee-noise floor for keeper-poked actions (USDC 6-dec).
    uint256 public constant MIN_ACTION_USD6 = 5e6;
    uint256 internal constant MAX_BUFFER_BPS = 5000;

    /*//////////////////////// Config ////////////////////////*/// @notice Scale from 6dp Core USDC to underlying units (1 for real USDC).
    uint256 public immutable coreScale;
    /// @notice Idle EVM cushion kept for instant vault recalls (bps, <= 5000).
    uint256 public bufferBps = 1500;
    /// @notice Per-action notional cap (USDC 6-dec; 0 = uncapped).
    uint256 public maxActionUsd6;
    bool public paused;

    /*//////////////////////// Core accounting (6dp USDC) ////////////////////////*/// @notice Net USDC sent to Core (principal only).
    uint64 public corePrincipal6;
    /// @notice Reserve supply value, last synced (0x811; falls back to principal).
    uint64 public supplyValue6;
    /// @notice Core spot USDC, last synced (0x801).
    uint64 public coreSpot6;
    uint256 public lastSync;

    /*//////////////////////// Profit (underlying units) ////////////////////////*/// @notice Profit bridged back to EVM.
    uint256 public profitRealized;
    /// @notice Profit already sent to the vault.
    uint256 public profitSwept;

    /*//////////////////////// Custom errors (EIP-170 size discipline) ////////////////////////*/error HLEarn__NotKeeper();
    error HLEarn__Paused();
    error HLEarn__NotInitialized();
    error HLEarn__ZeroAmount();
    error HLEarn__SubDust();
    error HLEarn__ExceedsBalance();
    error HLEarn__NeedSpot();
    error HLEarn__Cap();
    error HLEarn__BelowMin();
    error HLEarn__BufferTooHigh();
    error HLEarn__Inactive();
    error HLEarn__NotAuthorized();
    error HLEarn__DecimalsTooLow();
    error HLEarn__BelowSwept();

    /*//////////////////////// Read structs (mirror hyper-evm-lib) ////////////////////////*/struct BasisAndValue {
        uint64 basis;
        uint64 value;
    }

    struct BorrowLendUserTokenState {
        BasisAndValue borrow;
        BasisAndValue supply;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct CoreUserExists {
        bool exists;
    }

    /*//////////////////////// Events ////////////////////////*/event BridgeToCore(uint256 evmAmount, uint64 core6);
    event SupplySent(uint64 amount6, bytes data);
    event WithdrawSent(uint64 amount6, bytes data);
    event BridgeToEvm(uint64 amount6, uint64 principalRed6, uint64 profitRed6, bytes data);
    event EarnSynced(uint64 supplyValue6, uint64 coreSpot6, uint256 timestamp);
    event Recalled(uint256 requested, uint256 sent);
    event ProfitSwept(uint256 amount);
    event BufferSet(uint256 bufferBps);
    event PausedSet(bool paused);
    event MaxActionSet(uint256 maxActionUsd6);
    event ProfitReconciled(uint256 oldRealized, uint256 newRealized);

    constructor(address _underlying, address initialOwner, uint256 _maxActionUsd6)
        BaseStrategy(_underlying, initialOwner, "HLEarn")
    {
        uint8 dec = IERC20Metadata(_underlying).decimals();
        if (dec < 6) revert HLEarn__DecimalsTooLow();
        coreScale = 10 ** (dec - 6);
        maxActionUsd6 = _maxActionUsd6;
        lastSync = block.timestamp;
    }

    /*//////////////////////// Modifiers ////////////////////////*/modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert HLEarn__NotKeeper();
        _;
    }

    modifier notPaused() {
        if (paused) revert HLEarn__Paused();
        _;
    }

    modifier coreAccountRequired() {
        if (!_coreAccountExists()) revert HLEarn__NotInitialized();
        _;
    }

    /*//////////////////////// Reads ////////////////////////*/function _coreAccountExists() internal view returns (bool) {
        // Gas-capped reads: a FAILING precompile (stateless account) CONSUMES
        // the gas forwarded to it — an uncapped staticcall starves the rest of
        // the tx (observed live on testnet 2026-09-30: syncEarn needed >1.5M
        // gas until the account had lending state; 2.5M+ succeeded). The cap
        // bounds the loss so failure paths stay cheap.
        (bool ok, bytes memory ret) =
            HLConstants.CORE_USER_EXISTS_PRECOMPILE.staticcall{gas: 100_000}(abi.encode(address(this)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (CoreUserExists)).exists;
    }

    function coreAccountExists() external view returns (bool) {
        return _coreAccountExists();
    }

    /// @dev Failure-safe: (0,false) on any precompile hiccup.
    function _tryReadSupplyWei() internal view returns (uint64, bool) {
        (bool ok, bytes memory ret) = HLConstants.BORROW_LEND_USER_STATE_PRECOMPILE.staticcall{gas: 175_000}(
            abi.encode(address(this), HLConstants.USDC_TOKEN_INDEX)
        );
        if (!ok || ret.length < 128) return (0, false);
        BorrowLendUserTokenState memory s = abi.decode(ret, (BorrowLendUserTokenState));
        return (s.supply.value, true);
    }

    /// @dev Failure-safe: (0,false) on any precompile hiccup.
    function _tryReadSpotWei() internal view returns (uint64, bool) {
        (bool ok, bytes memory ret) = HLConstants.SPOT_BALANCE_PRECOMPILE.staticcall{gas: 100_000}(
            abi.encode(address(this), HLConstants.USDC_TOKEN_INDEX)
        );
        if (!ok || ret.length < 96) return (0, false);
        SpotBalance memory s = abi.decode(ret, (SpotBalance));
        return (s.total, true);
    }

    /// @notice Refresh the reserve value + Core spot reads. Permissionless:
    /// it only records what the precompiles report. If the supply read fails
    /// and nothing was ever recorded, fall back to PRINCIPAL (conservative —
    /// totalAssets must never overstate).
    function syncEarn() public {
        uint64 v;
        bool ok;
        (v, ok) = _tryReadSupplyWei();
        if (ok) {
            supplyValue6 = v / WEI_PER_UNIT;
        } else if (supplyValue6 == 0 && corePrincipal6 > 0) {
            supplyValue6 = corePrincipal6;
        }
        (v, ok) = _tryReadSpotWei();
        if (ok) {
            coreSpot6 = v / WEI_PER_UNIT;
        }
        lastSync = block.timestamp;
        emit EarnSynced(supplyValue6, coreSpot6, lastSync);
    }

    /*//////////////////////// Core flows (keeper) ////////////////////////*//// @notice Bridge USDC EVM→Core (lands in the contract's Core SPOT balance).
    /// Initializes the Core account on first use; actions (supply etc.) must be
    /// sent in a LATER block (init rule) — the keeper stages with waits.
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        if (evmAmount == 0) revert HLEarn__ZeroAmount();
        if (evmAmount % coreScale != 0) revert HLEarn__SubDust();
        if (evmAmount > underlying.balanceOf(address(this))) revert HLEarn__ExceedsBalance();
        uint64 usd6 = uint64(evmAmount / coreScale);
        if (maxActionUsd6 != 0 && usd6 > maxActionUsd6) revert HLEarn__Cap();
        corePrincipal6 += usd6;
        emit BridgeToCore(evmAmount, usd6);
        address wallet = HLConstants.coreDepositWallet();
        underlying.forceApprove(wallet, evmAmount);
        ICoreDepositWallet(wallet).deposit(evmAmount, HLConstants.SPOT_DEX);
    }

    /// @notice Supply USDC from the Core spot balance into the reserve
    /// (CoreWriter action 15, operation 0). Fire-and-forget: verify via
    /// syncEarn() after the action delay.
    function supplyToReserve(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (amount6 < MIN_ACTION_USD6) revert HLEarn__BelowMin();
        if (maxActionUsd6 != 0 && amount6 > maxActionUsd6) revert HLEarn__Cap();
        bytes memory data = HLEarnLib.encodeSupply(HLConstants.USDC_TOKEN_INDEX, amount6 * WEI_PER_UNIT);
        emit SupplySent(amount6, data);
        CORE_WRITER.sendRawAction(data);
    }

    /// @notice Withdraw USDC from the reserve back to the Core spot balance
    /// (action 15, operation 1). `amount6 = 0` withdraws the FULL reserve
    /// balance (wire semantic: wei = 0 → maximal).
    function requestWithdraw(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        bytes memory data;
        if (amount6 == 0) {
            data = HLEarnLib.encodeWithdrawMax(HLConstants.USDC_TOKEN_INDEX);
        } else {
            if (amount6 < MIN_ACTION_USD6) revert HLEarn__BelowMin();
            if (maxActionUsd6 != 0 && amount6 > maxActionUsd6) revert HLEarn__Cap();
            data = HLEarnLib.encodeWithdraw(HLConstants.USDC_TOKEN_INDEX, amount6 * WEI_PER_UNIT);
        }
        emit WithdrawSent(amount6, data);
        CORE_WRITER.sendRawAction(data);
    }

    /// @notice Send USDC from the Core SPOT balance back to EVM (action 13
    /// sendAsset to the USDC system address). Requires HYPE on Core for the
    /// transfer gas or it drops silently. The payout is split at the FRESHLY
    /// synced value: above-principal value realizes as PROFIT first; the rest
    /// reduces principal (DN profit-first rule — principal is never yield).
    function bridgeBackToEvm(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (amount6 == 0) revert HLEarn__ZeroAmount();
        if (amount6 < MIN_ACTION_USD6) revert HLEarn__BelowMin();
        if (maxActionUsd6 != 0 && amount6 > maxActionUsd6) revert HLEarn__Cap();
        syncEarn();
        if (amount6 > coreSpot6) revert HLEarn__NeedSpot();
        uint64 value6 = supplyValue6 + coreSpot6;
        uint64 profitAvail = value6 > corePrincipal6 ? value6 - corePrincipal6 : 0;
        uint64 profitRed = amount6 < profitAvail ? amount6 : profitAvail;
        uint64 principalRed = amount6 - profitRed;
        if (principalRed > corePrincipal6) revert HLEarn__ExceedsBalance();
        corePrincipal6 -= principalRed;
        coreSpot6 -= amount6;
        if (profitRed > 0) profitRealized += uint256(profitRed) * coreScale;
        bytes memory payload = abi.encode(
            address(HLConstants.BASE_SYSTEM_ADDRESS + HLConstants.USDC_TOKEN_INDEX),
            address(0),
            HLConstants.SPOT_DEX,
            HLConstants.SPOT_DEX,
            HLConstants.USDC_TOKEN_INDEX,
            amount6 * WEI_PER_UNIT
        );
        bytes memory action = abi.encodePacked(uint8(1), HLConstants.SEND_ASSET_ACTION, payload);
        emit BridgeToEvm(amount6, principalRed, profitRed, action);
        CORE_WRITER.sendRawAction(action);
    }

    /*//////////////////////// Vault recall ////////////////////////*//// @notice Vault-only: pay out idle EVM USDC (capped at balance, never
    /// reverts for illiquidity — the vault measures what arrived). Larger
    /// amounts are unwound by the keeper first (buffer discipline).
    function recall(uint256 amount) external override nonReentrant {
        if (msg.sender != vault) revert HLEarn__NotAuthorized();
        if (amount == 0) return;
        uint256 bal = underlying.balanceOf(address(this));
        uint256 sent = amount > bal ? bal : amount;
        if (sent > 0) underlying.safeTransfer(vault, sent);
        emit Recalled(amount, sent);
    }

    /*//////////////////////// Harvest (mirror DNCoreStrategy) ////////////////////////*//// @dev Keeper/owner: sync only (settle). Vault: sync + sweep realized
    /// profit above the liquidity buffer as REAL USDC to the vault.
    function _doHarvest() internal override returns (uint256 profit) {
        if (!isActive) revert HLEarn__Inactive();
        if (msg.sender != owner() && msg.sender != keeper && msg.sender != vault) revert HLEarn__NotAuthorized();
        syncEarn();
        if (msg.sender != vault) return 0;
        uint256 available = profitRealized > profitSwept ? profitRealized - profitSwept : 0;
        if (available == 0) return 0;
        uint256 bal = underlying.balanceOf(address(this));
        uint256 buffer = (totalAssets() * bufferBps) / 10000;
        uint256 sweepable = bal > buffer ? bal - buffer : 0;
        uint256 sweep = available < sweepable ? available : sweepable;
        if (sweep == 0) return 0;
        profitSwept += sweep;
        underlying.safeTransfer(vault, sweep);
        emit ProfitSwept(sweep);
        return sweep;
    }

    /*//////////////////////// Reconciliation (admin) ////////////////////////*/
    /// @notice Owner-only bookkeeping reconciliation: correct `profitRealized`
    /// when a dropped-and-retried CoreWriter action double-counted it (see
    /// docs/HLEARN_SLEEVE_DESIGN.md §Dress rehearsal open items). Funds-safe:
    /// the counter only sizes harvests; never settable below swept profit.
    function reconcileProfit(uint256 newRealized) external onlyOwner {
        if (newRealized < profitSwept) revert HLEarn__BelowSwept();
        uint256 old = profitRealized;
        profitRealized = newRealized;
        emit ProfitReconciled(old, newRealized);
    }

    /*//////////////////////// Views ////////////////////////*/function totalAssets() public view override returns (uint256) {
        return underlying.balanceOf(address(this)) + (uint256(supplyValue6) + uint256(coreSpot6)) * coreScale;
    }

    function harvestableProfit() external view returns (uint256) {
        return profitRealized > profitSwept ? profitRealized - profitSwept : 0;
    }

    /// @notice Keeper-facing state snapshot.
    function earnState()
        external
        view
        returns (uint64 principal6, uint64 supply6, uint64 spot6, uint256 realized, uint256 swept, uint256 syncedAt)
    {
        return (corePrincipal6, supplyValue6, coreSpot6, profitRealized, profitSwept, lastSync);
    }

    /*//////////////////////// Admin ////////////////////////*/function setBufferBps(uint256 bufferBps_) external onlyOwner {
        if (bufferBps_ > MAX_BUFFER_BPS) revert HLEarn__BufferTooHigh();
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setMaxActionUsd6(uint256 maxActionUsd6_) external onlyOwner {
        maxActionUsd6 = maxActionUsd6_;
        emit MaxActionSet(maxActionUsd6_);
    }
}
