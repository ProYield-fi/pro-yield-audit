// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HLConstants} from "./adapters/HLConstants.sol";
import {ICoreWriter, ICoreDepositWallet} from "./adapters/HLInterfaces.sol";

/// @title DNCoreStrategy — vault-integrated delta-neutral execution on HyperCore
/// @notice Production wiring of the CoreWriter adapter pattern into the vault
/// strategy interface (BaseStrategy). The contract is its own HyperCore actor:
/// it bridges USDC to Core, class-transfers to perp, places the short hedge,
/// and reads its Core equity back through the read precompiles.
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
///
/// NOTE: execution logic mirrors the tested DNCoreAdapter (26 byte-exact
/// tests). Consolidate both into a shared execution base before the audit.
contract DNCoreStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    /*//////////////////////// Config ////////////////////////*/
    uint32 public perpAsset;        // HyperCore perp asset index (0 = BTC, 1 = ETH)
    uint256 public maxActionUsd6;   // per-action notional cap, USDC 6dp
    uint256 public bufferBps = 1500; // liquidity buffer (basis points of assets, <= 5000)
    bool public paused;
    /// @notice Scale from Core 6dp USDC to underlying token units
    /// (1 for real USDC; 1e12 for an 18-decimals test token).
    uint256 public immutable coreScale;

    uint256 public constant MIN_ORDER_USD6 = 10e6;
    uint256 public constant MAX_BUFFER_BPS = 5000;

    /*//////////////////////// Core accounting (6dp, Core-native) ////////////////////////*/
    int256 public coreEquity6;      // Core account value (margin summary), last sync
    uint256 public corePrincipal6;  // net USDC sent to Core (principal only)
    int64 public lastPositionSzi;   // last synced perp position size
    uint256 public lastSync;

    /*//////////////////////// Profit (underlying units) ////////////////////////*/
    uint256 public profitRealized;  // profit bridged back to EVM
    uint256 public profitSwept;     // profit already sent to the vault

    /*//////////////////////// Read structs (mirror hyper-evm-lib) ////////////////////////*/
    struct Position { int64 szi; uint64 entryNtl; int64 isolatedRawUsd; uint32 leverage; bool isIsolated; }
    struct AccountMarginSummary { int64 accountValue; uint64 marginUsed; uint64 ntlPos; int64 rawUsd; }
    struct PerpAssetInfo { string coin; uint32 marginTableId; uint8 szDecimals; uint8 maxLeverage; bool onlyIsolated; }
    struct CoreUserExists { bool exists; }

    /*//////////////////////// Events ////////////////////////*/
    event BridgeToCore(uint256 evmAmount, uint64 coreAmount6);
    event BridgeToEvm(uint64 amount6, uint64 principalReduced6, uint64 profitRealized6);
    event ActionSent(uint24 indexed actionId, bytes data);
    event OrderSent(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif, uint128 cloid);
    event OrderCancelled(uint32 asset, uint128 cloid);
    event CoreSynced(int256 equity6, int64 szi, uint256 timestamp);
    event ProfitSwept(uint256 amount);
    event StakeDeposited(uint64 weiAmount);
    event StakeWithdrawn(uint64 weiAmount);
    event Delegated(address indexed validator, uint64 weiAmount, bool undelegate);
    event PausedSet(bool paused);
    event BufferSet(uint256 bufferBps);
    event MaxActionSet(uint256 maxActionUsd6);
    event PerpAssetSet(uint32 perpAsset);

    constructor(address _underlying, address initialOwner, uint32 _perpAsset, uint256 _maxActionUsd6)
        BaseStrategy(_underlying, initialOwner, "DeltaNeutralCore")
    {
        uint8 dec = IERC20Metadata(_underlying).decimals();
        require(dec >= 6, "DNCore: decimals < 6");
        coreScale = 10 ** (dec - 6);
        perpAsset = _perpAsset;
        maxActionUsd6 = _maxActionUsd6;
    }

    /*//////////////////////// Modifiers ////////////////////////*/
    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "DNCore: not keeper");
        _;
    }

    modifier notPaused() {
        require(!paused, "DNCore: paused");
        _;
    }

    /// @dev CoreWriter actions from an address whose HyperCore account does not
    /// exist are silently dropped. Gate every action on the 0x810 read.
    modifier coreAccountRequired() {
        require(_coreAccountExists(), "DNCore: Core account not initialized (bridge first, earlier block)");
        _;
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setBufferBps(uint256 bufferBps_) external onlyOwner {
        require(bufferBps_ <= MAX_BUFFER_BPS, "DNCore: buffer too high");
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }

    function setMaxActionUsd6(uint256 maxActionUsd6_) external onlyOwner {
        maxActionUsd6 = maxActionUsd6_;
        emit MaxActionSet(maxActionUsd6_);
    }

    /// @dev Only while flat — avoids reinterpreting an open hedge.
    function setPerpAsset(uint32 perpAsset_) external onlyOwner {
        Position memory p = position();
        require(p.szi == 0, "DNCore: position not flat");
        perpAsset = perpAsset_;
        emit PerpAssetSet(perpAsset_);
    }

    /*//////////////////////// Core account lifecycle ////////////////////////*/
    function coreAccountExists() external view returns (bool) {
        return _coreAccountExists();
    }

    /// @notice Bridge USDC EVM->Core (lands in the contract's SPOT balance).
    /// Initializes the Core account; actions must be sent in a LATER block.
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        require(evmAmount > 0, "DNCore: zero amount");
        require(evmAmount % coreScale == 0, "DNCore: sub-6dp dust");
        require(evmAmount <= underlying.balanceOf(address(this)), "DNCore: exceeds balance");
        uint64 core6 = uint64(evmAmount / coreScale);
        corePrincipal6 += core6;
        address wallet = HLConstants.coreDepositWallet();
        underlying.forceApprove(wallet, evmAmount);
        emit BridgeToCore(evmAmount, core6);
        ICoreDepositWallet(wallet).deposit(evmAmount, HLConstants.SPOT_DEX);
    }

    /// @notice Return USDC Core->EVM (sendAsset to the USDC system address).
    /// Requires HYPE on Core for transfer gas. Splits the amount into principal
    /// vs profit at the FRESHLY-SYNCED equity: profit = amount above remaining
    /// principal. Only realized profit can ever be harvested.
    function bridgeBackToEvm(uint64 amount6) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(amount6 > 0, "DNCore: zero amount");
        _syncCore();
        require(int256(uint256(amount6)) <= coreEquity6, "DNCore: exceeds Core equity");
        uint64 principalRed = amount6 > corePrincipal6 ? uint64(corePrincipal6) : amount6;
        uint64 profitRed = amount6 - principalRed;
        corePrincipal6 -= principalRed;
        coreEquity6 -= int256(uint256(amount6));
        if (profitRed > 0) {
            profitRealized += uint256(profitRed) * coreScale;
        }
        emit BridgeToEvm(amount6, principalRed, profitRed);
        _send(
            HLConstants.SEND_ASSET_ACTION,
            abi.encode(
                address(HLConstants.BASE_SYSTEM_ADDRESS + HLConstants.USDC_TOKEN_INDEX),
                address(0),
                HLConstants.SPOT_DEX,
                HLConstants.SPOT_DEX,
                HLConstants.USDC_TOKEN_INDEX,
                amount6
            )
        );
    }

    /*//////////////////////// Trading ////////////////////////*/
    function moveUsdcToPerp(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(ntl > 0 && uint256(ntl) <= maxActionUsd6, "DNCore: cap");
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, true));
    }

    function moveUsdcToSpot(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(ntl > 0 && uint256(ntl) <= maxActionUsd6, "DNCore: cap");
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, false));
    }

    /// @notice Open the short hedge (sell perp). limitPx/sz are 10^8 x human
    /// value; sz must respect szDecimals (read 0x80a before sizing).
    function openShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        _order(asset, false, false, limitPx, sz, tif);
    }

    /// @notice Unwind — buy back the short (reduceOnly).
    function closeShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        _order(asset, true, true, limitPx, sz, tif);
    }

    function cancelOrderByCloid(uint32 asset, uint128 cloid) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(asset == perpAsset, "DNCore: wrong asset");
        emit OrderCancelled(asset, cloid);
        _send(HLConstants.CANCEL_ORDER_BY_CLOID_ACTION, abi.encode(asset, cloid));
    }

    /// @dev notional(USDC 6dp) = limitPx * sz / 1e8 / 1e8 * 1e6 = limitPx * sz / 1e10.
    function _order(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif) internal {
        require(asset == perpAsset, "DNCore: wrong asset");
        require(limitPx > 0 && sz > 0, "DNCore: zero order");
        require(tif == HLConstants.TIF_ALO || tif == HLConstants.TIF_GTC || tif == HLConstants.TIF_IOC, "DNCore: bad tif");
        uint256 notional6 = (uint256(limitPx) * uint256(sz)) / 1e10;
        require(notional6 >= MIN_ORDER_USD6, "DNCore: below $10 min notional");
        require(notional6 <= maxActionUsd6, "DNCore: cap");
        uint128 cloid = 0;
        emit OrderSent(asset, isBuy, reduceOnly, limitPx, sz, tif, cloid);
        _send(HLConstants.LIMIT_ORDER_ACTION, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    /*//////////////////////// Staking (fee-discount path) ////////////////////////*/
    function stakeHype(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(weiAmount > 0, "DNCore: zero amount");
        emit StakeDeposited(weiAmount);
        _send(HLConstants.STAKING_DEPOSIT_ACTION, abi.encode(weiAmount));
    }

    function delegateHype(address validator, uint64 weiAmount, bool undelegate) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(validator != address(0), "DNCore: zero validator");
        emit Delegated(validator, weiAmount, undelegate);
        _send(HLConstants.TOKEN_DELEGATE_ACTION, abi.encode(validator, weiAmount, undelegate));
    }

    function withdrawStake(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(weiAmount > 0, "DNCore: zero amount");
        emit StakeWithdrawn(weiAmount);
        _send(HLConstants.STAKING_WITHDRAW_ACTION, abi.encode(weiAmount));
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
    function totalAssets() public view override returns (uint256) {
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
        require(isActive, "DNCore: inactive");
        require(msg.sender == owner() || msg.sender == keeper || msg.sender == vault, "DNCore: not authorized");
        _syncCore();
        if (msg.sender != vault) return 0; // keeper settles only; vault sweeps
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
        return sweep; // BaseStrategy.harvest books it via totalDebt
    }

    /*//////////////////////// Reads (precompiles) ////////////////////////*/
    function position() public view returns (Position memory) {
        (bool ok, bytes memory ret) = HLConstants.POSITION2_PRECOMPILE.staticcall(abi.encode(address(this), perpAsset));
        require(ok, "DNCore: position read failed");
        return abi.decode(ret, (Position));
    }

    function marginSummary() public view returns (AccountMarginSummary memory) {
        (bool ok, bytes memory ret) = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE.staticcall(abi.encode(uint32(0), address(this)));
        require(ok, "DNCore: margin read failed");
        return abi.decode(ret, (AccountMarginSummary));
    }

    function perpSzDecimals() public view returns (uint8) {
        (bool ok, bytes memory ret) = HLConstants.PERP_ASSET_INFO_PRECOMPILE.staticcall(abi.encode(perpAsset));
        require(ok, "DNCore: asset info read failed");
        return abi.decode(ret, (PerpAssetInfo)).szDecimals;
    }

    function oraclePx() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.ORACLE_PX_PRECOMPILE.staticcall(abi.encode(perpAsset));
        require(ok, "DNCore: oracle read failed");
        return abi.decode(ret, (uint64));
    }

    /*//////////////////////// Internals ////////////////////////*/
    function _coreAccountExists() internal view returns (bool) {
        (bool ok, bytes memory ret) = HLConstants.CORE_USER_EXISTS_PRECOMPILE.staticcall(abi.encode(address(this)));
        require(ok, "DNCore: coreUserExists read failed");
        return abi.decode(ret, (CoreUserExists)).exists;
    }

    function _send(uint24 actionId, bytes memory payload) internal {
        bytes memory data = abi.encodePacked(uint8(1), actionId, payload);
        emit ActionSent(actionId, data);
        CORE_WRITER.sendRawAction(data);
    }
}
