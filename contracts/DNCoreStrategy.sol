// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DNCoreBase} from "./adapters/DNCoreBase.sol";

/// @title DNCoreStrategy — vault-integrated delta-neutral execution on HyperCore
/// @notice The vault strategy wrapper over DNCoreBase (the shared execution
/// layer). The contract is its own HyperCore actor: it bridges USDC to Core,
/// class-transfers to perp, places the short hedge, and reads its Core equity
/// back through the read precompiles. Execution lives ONCE in DNCoreBase;
/// this contract adds the honest-accounting + vault wiring.
///
/// HONEST ACCOUNTING (repo discipline — see SkyStrategy/MorphoStrategy audits):
/// - `corePrincipal6`  = net USDC we sent to Core (never counted as yield).
/// - `coreEquity6`     = Core account value, refreshed by syncCore() reads.
/// - profit on Core    = equity - principal; only the EXCESS is realizable.
/// - `profitRealized`  = profit actually bridged back to EVM (underlying units).
/// - harvest() by the VAULT sweeps realized profit above the liquidity buffer
///   to the vault; by the keeper it only syncs (settle, no movement).
///
/// ASYNC RECALL (CoreWriter actions are fire-and-forget + delayed seconds):
/// - This contract keeps `bufferBps` of assets idle on EVM for instant vault
///   recalls (BaseStrategy.recall is vault-only, transfers idle balance).
/// - Larger recalls: keeper unwinds first (moveUsdcToSpot -> bridgeBackToEvm),
///   then the vault recalls. Documented in docs/DN_COREWRITER_ADAPTER.md.
contract DNCoreStrategy is BaseStrategy, DNCoreBase {
    using SafeERC20 for IERC20;

    /*//////////////////////// Config ////////////////////////*/
    /// @notice Scale from Core 6dp USDC to underlying token units
    /// (1 for real USDC; 1e12 for an 18-decimals test token).
    uint256 public immutable coreScale;
    uint256 public bufferBps = 1500; // liquidity buffer (bps of assets, <= 5000)
    uint256 public constant MAX_BUFFER_BPS = 5000;

    /*//////////////////////// Core accounting (6dp, Core-native) ////////////////////////*/
    int256 public coreEquity6;      // Core account value (margin summary), last sync
    uint256 public corePrincipal6;  // net USDC sent to Core (principal only)
    int64 public lastPositionSzi;   // last synced perp position size
    uint256 public lastSync;

    /*//////////////////////// Profit (underlying units) ////////////////////////*/
    uint256 public profitRealized;  // profit bridged back to EVM
    uint256 public profitSwept;     // profit already sent to the vault

    /*//////////////////////// Custom errors (EIP-170 size discipline) ////////////////////////*/
    error DNCore__DecimalsTooLow();
    error DNCore__SubDust();
    error DNCore__ExceedsBalance();
    error DNCore__ExceedsEquity();
    error DNCore__BufferTooHigh();
    error DNCore__Inactive();
    error DNCore__NotAuthorized();

    /*//////////////////////// Events (strategy-specific) ////////////////////////*/
    event BridgeToCore(uint256 evmAmount, uint64 coreAmount6);
    event BridgeToEvm(uint64 amount6, uint64 principalReduced6, uint64 profitRealized6);
    event CoreSynced(int256 equity6, int64 szi, uint256 timestamp);
    event ProfitSwept(uint256 amount);
    event BufferSet(uint256 bufferBps);

    constructor(address _underlying, address initialOwner, uint32 _perpAsset, uint256 _maxActionUsd6)
        BaseStrategy(_underlying, initialOwner, "DeltaNeutralCore")
        DNCoreBase(_perpAsset, _maxActionUsd6)
    {
        uint8 dec = IERC20Metadata(_underlying).decimals();
        if (dec < 6) revert DNCore__DecimalsTooLow();
        coreScale = 10 ** (dec - 6);
    }

    /*//////////////////////// BaseStrategy seams ////////////////////////*/
    function _keeper() internal view override returns (address) {
        return keeper; // BaseStrategy.keeper (owner-set)
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setBufferBps(uint256 bufferBps_) external onlyOwner {
        if (bufferBps_ > MAX_BUFFER_BPS) revert DNCore__BufferTooHigh();
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    /*//////////////////////// Core account lifecycle ////////////////////////*/
    /// @notice Bridge USDC EVM->Core (lands in the contract's SPOT balance).
    /// Initializes the Core account; actions must be sent in a LATER block.
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        if (evmAmount == 0) revert DNCore__ZeroAmount();
        if (evmAmount % coreScale != 0) revert DNCore__SubDust();
        if (evmAmount > underlying.balanceOf(address(this))) revert DNCore__ExceedsBalance();
        uint64 core6 = uint64(evmAmount / coreScale);
        corePrincipal6 += core6;
        emit BridgeToCore(evmAmount, core6);
        _bridgeUsdcIn(underlying, evmAmount);
    }

    /// @notice Return USDC Core->EVM (sendAsset to the USDC system address).
    /// Requires HYPE on Core for transfer gas. Splits the amount at the
    /// FRESHLY-SYNCED equity: while equity > principal, an outflow draws from
    /// the PROFIT portion FIRST (principal stays invested, keeping the hedge
    /// margin sized), so a profit-sized skim realizes profit instead of
    /// silently consuming principal basis (round-2 HIGH-1).
    ///   profitAvail = max(0, equity - principal)
    ///   profitRed   = min(amount, profitAvail);  principalRed = amount - profitRed
    /// Full-amount drains are unchanged (profitAvail is realized, the rest is
    /// principal); in a loss (equity < principal) every unit is principal.
    function bridgeBackToEvm(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (amount6 == 0) revert DNCore__ZeroAmount();
        _syncCore();
        if (int256(uint256(amount6)) > coreEquity6) revert DNCore__ExceedsEquity();
        uint64 profitAvail = coreEquity6 > int256(corePrincipal6)
            ? uint64(uint256(coreEquity6 - int256(corePrincipal6)))
            : 0;
        uint64 profitRed = amount6 < profitAvail ? amount6 : profitAvail;
        uint64 principalRed = amount6 - profitRed;
        corePrincipal6 -= principalRed;
        coreEquity6 -= int256(uint256(amount6));
        if (profitRed > 0) {
            profitRealized += uint256(profitRed) * coreScale;
        }
        emit BridgeToEvm(amount6, principalRed, profitRed);
        _sendUsdcToEvm(amount6);
    }

    /*//////////////////////// Core sync (read precompiles) ////////////////////////*/
    /// @notice Refresh Core equity + position from HyperCore state. Permissionless:
    /// it only records what the precompiles report.
    function syncCore() external {
        _syncCore();
    }

    function _syncCore() internal {
        AccountMarginSummary memory m = marginSummary();
        coreEquity6 = int256(m.accountValue);
        lastPositionSzi = position().szi;
        lastSync = block.timestamp;
        emit CoreSynced(coreEquity6, lastPositionSzi, lastSync);
    }

    /// @notice Keeper-facing state snapshot.
    function coreState() external view returns (
        int256 equity6, uint256 principal6, int64 szi, uint256 realized, uint256 swept, uint256 syncedAt
    ) {
        return (coreEquity6, corePrincipal6, lastPositionSzi, profitRealized, profitSwept, lastSync);
    }

    /// @notice Strategy assets in underlying units (synced Core equity + idle).
    function totalAssets() public view override(BaseStrategy) returns (uint256) {
        uint256 eqU = coreEquity6 > 0 ? uint256(coreEquity6) * coreScale : 0;
        return eqU + underlying.balanceOf(address(this));
    }

    /// @notice Realized profit still waiting to be swept (underlying units).
    function harvestableProfit() external view returns (uint256) {
        return profitRealized > profitSwept ? profitRealized - profitSwept : 0;
    }

    /*//////////////////////// Harvest ////////////////////////*/
    /// @dev Keeper/owner: sync only (settle). Vault: sync + sweep realized
    /// profit above the liquidity buffer as REAL USDC to the vault.
    function _doHarvest() internal override returns (uint256 profit) {
        if (!isActive) revert DNCore__Inactive();
        if (msg.sender != owner() && msg.sender != keeper && msg.sender != vault) revert DNCore__NotAuthorized();
        _syncCore();
        if (msg.sender != vault) return 0; // keeper settles only; vault sweeps
        uint256 available = profitRealized > profitSwept ? profitRealized - profitSwept : 0;
        if (available == 0) return 0;
        // buffer = pct of assets kept idle for async recalls
        uint256 bal = underlying.balanceOf(address(this));
        uint256 buffer = (totalAssets() * bufferBps) / 10000;
        uint256 sweepable = bal > buffer ? bal - buffer : 0;
        uint256 sweep = available < sweepable ? available : sweepable;
        if (sweep == 0) return 0;
        profitSwept += sweep;
        underlying.safeTransfer(vault, sweep);
        emit ProfitSwept(sweep);
        return sweep; // BaseStrategy.harvest books it via totalDebt
    }
}
