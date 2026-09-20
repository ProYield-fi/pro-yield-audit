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
    error DNCore__ZeroValidator();
    error DNCore__NotFlat();
    error DNCore__ReadFailed();

    /*//////////////////////// Read structs (mirror hyper-evm-lib) ////////////////////////*/
    struct Position { int64 szi; uint64 entryNtl; int64 isolatedRawUsd; uint32 leverage; bool isIsolated; }
    struct AccountMarginSummary { int64 accountValue; uint64 marginUsed; uint64 ntlPos; int64 rawUsd; }
    struct PerpAssetInfo { string coin; uint32 marginTableId; uint8 szDecimals; uint8 maxLeverage; bool onlyIsolated; }
    struct CoreUserExists { bool exists; }

    /*//////////////////////// Events (shared execution surface) ////////////////////////*/
    event ActionSent(uint24 indexed actionId, bytes data);
    event OrderSent(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif, uint128 cloid);
    event OrderCancelled(uint32 asset, uint128 cloid);
    event StakeDeposited(uint64 weiAmount);
    event StakeWithdrawn(uint64 weiAmount);
    event Delegated(address indexed validator, uint64 weiAmount, bool undelegate);
    event PausedSet(bool paused);
    event MaxActionSet(uint256 maxActionUsd6);
    event PerpAssetSet(uint32 perpAsset);

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

    function setMaxActionUsd6(uint256 maxActionUsd6_) external onlyOwner {
        maxActionUsd6 = maxActionUsd6_;
        emit MaxActionSet(maxActionUsd6_);
    }

    /// @dev Only while the position is flat — avoids reinterpreting an open hedge.
    function setPerpAsset(uint32 perpAsset_) external onlyOwner {
        Position memory p = position();
        if (p.szi != 0) revert DNCore__NotFlat();
        perpAsset = perpAsset_;
        emit PerpAssetSet(perpAsset_);
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
        _order(asset, false, false, limitPx, sz, tif);
    }

    /// @notice Unwind — buy back the short (reduceOnly).
    function closeShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        _order(asset, true, true, limitPx, sz, tif);
    }

    function cancelOrderByCloid(uint32 asset, uint128 cloid) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        if (asset != perpAsset) revert DNCore__WrongAsset();
        emit OrderCancelled(asset, cloid);
        _send(HLConstants.CANCEL_ORDER_BY_CLOID_ACTION, abi.encode(asset, cloid));
    }

    /// @dev notional(USDC 6dp) = limitPx * sz / 1e8 / 1e8 * 1e6 = limitPx * sz / 1e10.
    function _order(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif) internal {
        if (asset != perpAsset) revert DNCore__WrongAsset();
        if (limitPx == 0 || sz == 0) revert DNCore__ZeroOrder();
        if (tif != HLConstants.TIF_ALO && tif != HLConstants.TIF_GTC && tif != HLConstants.TIF_IOC) revert DNCore__BadTif();
        uint256 notional6 = (uint256(limitPx) * uint256(sz)) / 1e10;
        if (notional6 < MIN_ORDER_USD6) revert DNCore__BelowMinNotional();
        if (notional6 > maxActionUsd6) revert DNCore__Cap();
        uint128 cloid = 0;
        emit OrderSent(asset, isBuy, reduceOnly, limitPx, sz, tif, cloid);
        _send(HLConstants.LIMIT_ORDER_ACTION, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    /*//////////////////////// Staking (fee-discount path) ////////////////////////*/
    /// @notice Stake HYPE held on the contract's Core spot balance (action 4).
    /// Owner-gated: policy op, not routine keeper work.
    function stakeHype(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        if (weiAmount == 0) revert DNCore__ZeroAmount();
        emit StakeDeposited(weiAmount);
        _send(HLConstants.STAKING_DEPOSIT_ACTION, abi.encode(weiAmount));
    }

    /// @notice Delegate / undelegate staked HYPE to a validator (action 3).
    function delegateHype(address validator, uint64 weiAmount, bool undelegate) external onlyOwner notPaused coreAccountRequired nonReentrant {
        if (validator == address(0)) revert DNCore__ZeroValidator();
        emit Delegated(validator, weiAmount, undelegate);
        _send(HLConstants.TOKEN_DELEGATE_ACTION, abi.encode(validator, weiAmount, undelegate));
    }

    /// @notice Withdraw HYPE from staking back to Core spot (action 5).
    function withdrawStake(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        if (weiAmount == 0) revert DNCore__ZeroAmount();
        emit StakeWithdrawn(weiAmount);
        _send(HLConstants.STAKING_WITHDRAW_ACTION, abi.encode(weiAmount));
    }

    /*//////////////////////// Reads (precompiles) ////////////////////////*/
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

    function withdrawable() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.WITHDRAWABLE_PRECOMPILE.staticcall(abi.encode(address(this)));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (uint64));
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

    function markPx() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.MARK_PX_PRECOMPILE.staticcall(abi.encode(perpAsset));
        if (!ok) revert DNCore__ReadFailed();
        return abi.decode(ret, (uint64));
    }

    /*//////////////////////// Internals ////////////////////////*/
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
