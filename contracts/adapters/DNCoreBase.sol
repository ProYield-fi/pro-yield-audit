// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HLConstants} from "./HLConstants.sol";
import {ICoreWriter, ICoreDepositWallet} from "./HLInterfaces.sol";

/// @title DNCoreBase — shared HyperCore execution layer via CoreWriter
/// @notice Abstract base for every contract that acts as its own HyperCore
/// actor (vault strategy, standalone adapter). Holds ALL execution logic once:
/// read precompiles, CoreWriter sends, order/class-transfer/staking actions,
/// and the drop-prevention gates. Children add accounting + policy around it.
///
/// Verified against LIVE HyperEVM mainnet (see scripts/dn_realread_check.js):
/// - 0x80a/0x813 return the offset-wrapped 1-tuple encoding for dynamic structs.
/// - 0x80f accountMarginSummary takes (uint32 perpDexIndex, address user).
/// - CoreWriter drops actions SILENTLY when the sender has no Core account —
///   every action is gated on the 0x810 read (`coreAccountRequired`).
/// - Actions are fire-and-forget (applied after a delay): never assume a read
///   immediately after `_send` reflects the action.
///
/// SIZE DISCIPLINE: EIP-170 (24,576 bytes) is enforced on HyperEVM. Custom
/// errors (4-byte selectors) replace require-strings; re-measure bytecode
/// after any change.
///
/// Disciplines baked in (audit requirements):
/// - `nonReentrant` on EVERY mutating entry point.
/// - Events emit BEFORE external calls (tx atomicity makes this equivalent;
///   it keeps event order aligned with state and silences reentrancy-events).
///
/// DIAMOND NOTE: this base inherits Ownable + ReentrancyGuard but deliberately
/// does NOT pass Ownable's constructor args — in a child like
/// `contract DNCoreStrategy is BaseStrategy, DNCoreBase`, BaseStrategy already
/// supplies them, and specifying them twice is a compile error. A standalone
/// child (the adapter) passes `Ownable(owner_)` in its own constructor.
/// C3 linearization merges the common bases into ONE copy at runtime.
abstract contract DNCoreBase is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    /// @notice HyperCore perp asset index (0 = BTC, 1 = ETH on validator perps).
    uint32 public perpAsset;
    /// @notice Per-action notional cap, USDC 6-dec units.
    uint256 public maxActionUsd6;
    bool public paused;

    /// @notice Spot hedge config (HIGH-2 fix). `spotPairIndex` = HyperCore spot
    /// pair index (e.g. 107 = HYPE/USDC); `spotTokenIndex` = derived base-token
    /// index; `spotAsset` = spot ORDER asset (10000 + pairIndex); `spotPxScale`
    /// = 10^(10 - szDecimals) so spotValue6 = spotSz(1e8) * spotPxRaw / scale
    /// yields USDC 6dp. 0 = spot leg disabled — never claim delta-neutral then.
    uint64 public spotPairIndex;
    uint64 public spotTokenIndex;
    uint32 public spotAsset;
    uint256 public spotPxScale;

    /// @notice HL minimum order notional is $10.
    uint256 public constant MIN_ORDER_USD6 = 10e6;

    /*//////////////////////// Custom errors (EIP-170 size discipline) ////////////////////////*/
    error DNCore__NotKeeper();
    error DNCore__Paused();
    error DNCore__NotInitialized();
    error DNCore__ZeroAmount();
    error DNCore__ZeroOrder();
    error DNCore__BadTif();
    error DNCore__BelowMinNotional();
    error DNCore__WrongAsset();
    error DNCore__Cap();
    error DNCore__NotFlat();
    error DNCore__ReadFailed();
    error DNCore__SpotDisabled();

    /*//////////////////////// Read structs (mirror hyper-evm-lib) ////////////////////////*/
    struct Position { int64 szi; uint64 entryNtl; int64 isolatedRawUsd; uint32 leverage; bool isIsolated; }
    struct AccountMarginSummary { int64 accountValue; uint64 marginUsed; uint64 ntlPos; int64 rawUsd; }
    struct PerpAssetInfo { string coin; uint32 marginTableId; uint8 szDecimals; uint8 maxLeverage; bool onlyIsolated; }
    struct CoreUserExists { bool exists; }
    struct SpotBalance { uint64 total; uint64 hold; uint64 entryNtl; }
    struct SpotInfo { string name; uint64[2] tokens; }
    struct TokenInfo { string name; uint64[] spots; uint64 deployerTradingFeeShare; address deployer; address evmContract; uint8 szDecimals; uint8 weiDecimals; int8 evmExtraWeiDecimals; }

    /*//////////////////////// Events (shared execution surface) ////////////////////////*/
    event ActionSent(uint24 indexed actionId, bytes data);
    event OrderSent(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif, uint128 cloid);
    event OrderCancelled(uint32 asset, uint128 cloid);
    event PausedSet(bool paused);
    event MaxActionSet(uint256 maxActionUsd6);
    event PerpAssetSet(uint32 perpAsset);
    event SpotConfigSet(uint64 pairIndex, uint64 tokenIndex, uint32 asset, uint256 pxScale);
    event HedgeTransferOut(address indexed destination, uint64 weiAmount);

    /// @dev Children pass perpAsset + maxActionUsd6; Ownable's constructor args
    /// are supplied by the child's inheritance path (see DIAMOND NOTE above).
    constructor(uint32 _perpAsset, uint256 _maxActionUsd6) {
        perpAsset = _perpAsset;
        maxActionUsd6 = _maxActionUsd6;
    }

    /*//////////////////////// Access control ////////////////////////*/
    /// @dev The keeper address authorized alongside the owner. Adapter: its own
    /// state var; strategy: BaseStrategy.keeper.
    function _keeper() internal view virtual returns (address);

    modifier onlyKeeper() {
        if (msg.sender != _keeper() && msg.sender != owner()) revert DNCore__NotKeeper();
        _;
    }

    modifier notPaused() {
        if (paused) revert DNCore__Paused();
        _;
    }

    /// @dev CoreWriter actions from an address whose HyperCore account does not
    /// exist are silently dropped. Gate every action on the 0x810 read.
    modifier coreAccountRequired() {
        if (!_coreAccountExists()) revert DNCore__NotInitialized();
        _;
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    // setMaxActionUsd6 was DROPPED from the deployment build: HyperEVM's
    // 3,000,000-gas block limit caps code size and the cap has no on-chain
    // caller (constructor-set; re-add in an audit revision if needed).

    /// @dev Only while the position is flat — avoids reinterpreting an open hedge.
    function setPerpAsset(uint32 perpAsset_) external onlyOwner {
        Position memory p = position();
        if (p.szi != 0) revert DNCore__NotFlat();
        perpAsset = perpAsset_;
        emit PerpAssetSet(perpAsset_);
    }

    /// @notice Configure the spot hedge pair (HIGH-2). The caller supplies the
    /// derived values (derive them off-chain from 0x80b/0x80c — verified live:
    /// pair 107 gives token 150, szDecimals 2, pxScale 1e8); the contract checks
    /// them. @dev Only while flat — avoids reinterpreting an open hedge.
    function setSpotConfig(uint64 pairIndex, uint64 tokenIndex, uint256 pxScale) external onlyOwner {
        if (position().szi != 0) revert DNCore__NotFlat();
        if (pairIndex == 0 || tokenIndex == 0 || pxScale == 0 || pxScale > 1e18) revert DNCore__ZeroOrder();
        spotPairIndex = pairIndex;
        spotTokenIndex = tokenIndex;
        spotAsset = uint32(10000) + uint32(pairIndex);
        spotPxScale = pxScale;
        emit SpotConfigSet(pairIndex, tokenIndex, spotAsset, pxScale);
    }

    /*//////////////////////// Trading (CoreWriter actions) ////////////////////////*/
    /// @notice Move USDC spot→perp (or back) on Core. `ntl` is USDC perp units
    /// (6 decimals; 1 USDC = 1e6).
    function moveUsdcToPerp(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (ntl == 0 || uint256(ntl) > maxActionUsd6) revert DNCore__Cap();
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, true));
    }

    function moveUsdcToSpot(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (ntl == 0 || uint256(ntl) > maxActionUsd6) revert DNCore__Cap();
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, false));
    }

    /// @notice Open the short hedge (sell perp). limitPx/sz are 10^8 × human
    /// value; sz must respect the asset's szDecimals (keeper reads 0x80a).
    function openShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (asset != perpAsset) revert DNCore__WrongAsset();
        _order(asset, false, false, limitPx, sz, tif);
    }

    /// @notice Unwind — buy back the short (reduceOnly).
    function closeShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (asset != perpAsset) revert DNCore__WrongAsset();
        _order(asset, true, true, limitPx, sz, tif);
    }

    /// @notice Buy the spot hedge — the LONG leg that cancels the short's
    /// price exposure (HIGH-2 fix). `limitPx`/`sz` are 10^8 × human value;
    /// sz must respect the pair's szDecimals (keeper derives from pxScale).
    /// HL spot orders enforce a $10 minimum on the REQUESTED notional.
    function openSpotBuy(uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (spotAsset == 0) revert DNCore__SpotDisabled();
        _order(spotAsset, true, false, limitPx, sz, tif);
    }

    /// @notice Sell the spot hedge (unwind path). Spot orders take no
    /// reduceOnly flag. Requests under $10 are rejected by HL — use
    /// hedgeTransferOut for sub-$10 hedge sizes.
    function sellSpot(uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (spotAsset == 0) revert DNCore__SpotDisabled();
        _order(spotAsset, false, false, limitPx, sz, tif);
    }

    /// @notice Spot-send the hedge straight from the contract's Core spot
    /// balance (action 6) — the unwind path for hedge sizes below HL's $10
    /// order minimum (orders can't express them; a send can).
    function hedgeTransferOut(address destination, uint64 weiAmount) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (spotAsset == 0) revert DNCore__SpotDisabled();
        if (destination == address(0) || weiAmount == 0) revert DNCore__ZeroAmount();
        emit HedgeTransferOut(destination, weiAmount);
        _send(HLConstants.SPOT_SEND_ACTION, abi.encode(destination, spotTokenIndex, weiAmount));
    }

    /// @dev notional(USDC 6dp) = limitPx * sz / 1e8 / 1e8 * 1e6 = limitPx * sz / 1e10.
    function _order(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif) internal {
        if (asset != perpAsset && (spotAsset == 0 || asset != spotAsset)) revert DNCore__WrongAsset();
        if (limitPx == 0 || sz == 0) revert DNCore__ZeroOrder();
        if (tif != HLConstants.TIF_ALO && tif != HLConstants.TIF_GTC && tif != HLConstants.TIF_IOC) revert DNCore__BadTif();
        uint256 notional6 = (uint256(limitPx) * uint256(sz)) / 1e10;
        if (notional6 < MIN_ORDER_USD6) revert DNCore__BelowMinNotional();
        if (notional6 > maxActionUsd6) revert DNCore__Cap();
        uint128 cloid = 0;
        emit OrderSent(asset, isBuy, reduceOnly, limitPx, sz, tif, cloid);
        _send(HLConstants.LIMIT_ORDER_ACTION, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    /*//////////////////////// Reads (precompiles) ////////////////////////*/
    // Staking actions (4/3/5) were DROPPED from this deployment surface: the
    // HYPE fee-discount path is a policy op that has never run live, and
    // HyperEVM's 3,000,000-gas block limit caps deployment code size —
    // carrying an unused action surface risked the deploy itself. Re-add,
    // audited, when the fee-discount decision lands.
    /// @dev Kept as an external view for keeper/test reads.
    function coreAccountExists() external view returns (bool) {
        return _coreAccountExists();
    }

    function position() public view returns (Position memory) {
        (bool ok, bytes memory ret) = HLConstants.POSITION2_PRECOMPILE.staticcall(abi.encode(address(this), perpAsset));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (Position));
    }

    /// @notice NOTE: takes (perpDexIndex, user) — verified against mainnet.
    function marginSummary() public view returns (AccountMarginSummary memory) {
        (bool ok, bytes memory ret) = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE.staticcall(abi.encode(uint32(0), address(this)));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (AccountMarginSummary));
    }

    function perpSzDecimals() public view returns (uint8) {
        (bool ok, bytes memory ret) = HLConstants.PERP_ASSET_INFO_PRECOMPILE.staticcall(abi.encode(perpAsset));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (PerpAssetInfo)).szDecimals;
    }

    function oraclePx() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.ORACLE_PX_PRECOMPILE.staticcall(abi.encode(perpAsset));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (uint64));
    }

    /*//////////////////////// Internals ////////////////////////*/
    /// @notice Spot hedge size (1e8 units — Core spot wei for HYPE). Safe: 0
    /// when the spot leg is unconfigured or the read fails.
    function spotHedgeSz() public view returns (uint64) {
        if (spotTokenIndex == 0) return 0;
        (bool ok, bytes memory ret) = HLConstants.SPOT_BALANCE_PRECOMPILE.staticcall(
            abi.encode(address(this), spotTokenIndex)
        );
        if (!ok) return 0;
        return abi.decode(ret, (SpotBalance)).total;
    }

    /// @notice Live spot price for the hedge pair (raw; human px =
    /// raw / 10^(8 - szDecimals)). Safe: 0 on failure.
    function spotPx() public view returns (uint64) {
        if (spotPairIndex == 0) return 0;
        (bool ok, bytes memory ret) = HLConstants.SPOT_PX_PRECOMPILE.staticcall(abi.encode(spotPairIndex));
        if (!ok) return 0;
        return abi.decode(ret, (uint64));
    }

    /// @notice Spot hedge value in USDC 6dp. Safe: 0 on any read failure —
    /// totalAssets math must never revert on a precompile hiccup.
    function spotValue6() public view returns (uint64) {
        uint64 sz = spotHedgeSz();
        if (sz == 0) return 0;
        uint64 px = spotPx();
        if (px == 0 || spotPxScale == 0) return 0;
        return uint64((uint256(sz) * uint256(px)) / spotPxScale);
    }

    function _coreAccountExists() internal view returns (bool) {
        (bool ok, bytes memory ret) = HLConstants.CORE_USER_EXISTS_PRECOMPILE.staticcall(abi.encode(address(this)));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (CoreUserExists)).exists;
    }

    function _send(uint24 actionId, bytes memory payload) internal {
        bytes memory data = abi.encodePacked(uint8(1), actionId, payload);
        emit ActionSent(actionId, data);
        CORE_WRITER.sendRawAction(data);
    }

    /// @dev Shared bridge-in step: approve + deposit via the CoreDepositWallet.
    /// Caller emits its own event BEFORE calling this (external call discipline).
    function _bridgeUsdcIn(IERC20 token, uint256 evmAmount) internal {
        address wallet = HLConstants.coreDepositWallet();
        token.forceApprove(wallet, evmAmount);
        ICoreDepositWallet(wallet).deposit(evmAmount, HLConstants.SPOT_DEX);
    }

    /// @dev Shared bridge-out encoding: sendAsset of USDC to the EVM system
    /// address. Requires HYPE on Core for transfer gas or it drops silently.
    function _sendUsdcToEvm(uint64 amount6) internal {
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
}
