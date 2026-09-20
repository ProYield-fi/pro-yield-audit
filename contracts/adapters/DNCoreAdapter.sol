// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HLConstants} from "./HLConstants.sol";
import {ICoreWriter, ICoreDepositWallet} from "./HLInterfaces.sol";

/// @title DNCoreAdapter — delta-neutral execution layer on HyperCore via CoreWriter
/// @notice The contract is its own HyperCore actor: bridge USDC in, class-transfer
/// to perp, place the short hedge, unwind. Keeper pokes; owner sets policy.
/// Fire-and-forget discipline: every action is preceded by the on-chain checks
/// that prevent silent drops (account exists, caps, min notional, asset whitelist).
/// See docs/DN_COREWRITER_ADAPTER.md for the full design + rollout gates.
contract DNCoreAdapter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    /// @notice USDC on HyperEVM (constructor arg for testability; deploy scripts
    /// pass HLConstants.usdc() — chainid-aware mainnet/testnet).
    IERC20 public immutable usdc;
    address public keeper;
    /// @notice HyperCore perp asset index (0 = BTC, 1 = ETH on validator perps).
    uint32 public perpAsset;
    /// @notice Per-action notional cap in USDC 6-dec units.
    uint256 public maxActionUsd6;
    bool public paused;

    /// @notice HL minimum order notional is $10.
    uint256 public constant MIN_ORDER_USD6 = 10e6;

    /*//////////////////////// Read structs (mirror hyper-evm-lib) ////////////////////////*/
    struct Position {
        int64 szi; // signed size — negative = short
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }
    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }
    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }
    struct CoreUserExists {
        bool exists;
    }

    /*//////////////////////// Events ////////////////////////*/
    event BridgeToCore(uint256 evmAmount);
    event BridgeToEvm(uint64 weiAmount);
    event ActionSent(uint24 indexed actionId, bytes data);
    event OrderSent(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif, uint128 cloid);
    event OrderCancelled(uint32 asset, uint128 cloid);
    event StakeDeposited(uint64 weiAmount);
    event StakeWithdrawn(uint64 weiAmount);
    event Delegated(address indexed validator, uint64 weiAmount, bool undelegate);
    event KeeperSet(address indexed keeper);
    event PausedSet(bool paused);
    event MaxActionSet(uint256 maxActionUsd6);
    event PerpAssetSet(uint32 perpAsset);

    constructor(address owner_, address keeper_, address usdc_, uint32 perpAsset_, uint256 maxActionUsd6_) Ownable(owner_) {
        require(keeper_ != address(0), "adapter: zero keeper");
        require(usdc_ != address(0), "adapter: zero usdc");
        keeper = keeper_;
        usdc = IERC20(usdc_);
        perpAsset = perpAsset_;
        maxActionUsd6 = maxActionUsd6_;
    }

    /*//////////////////////// Modifiers ////////////////////////*/
    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "adapter: not keeper");
        _;
    }

    modifier notPaused() {
        require(!paused, "adapter: paused");
        _;
    }

    /// @dev Prevents silent drops: CoreWriter actions from an address whose
    /// HyperCore account does not yet exist are discarded with no error.
    modifier coreAccountRequired() {
        require(_coreAccountExists(), "adapter: Core account not initialized (bridge first, earlier block)");
        _;
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setKeeper(address keeper_) external onlyOwner {
        require(keeper_ != address(0), "adapter: zero keeper");
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

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
        require(p.szi == 0, "adapter: position not flat");
        perpAsset = perpAsset_;
        emit PerpAssetSet(perpAsset_);
    }

    /*//////////////////////// Core account lifecycle ////////////////////////*/
    function coreAccountExists() external view returns (bool) {
        return _coreAccountExists();
    }

    /// @notice Step 1 — bridge USDC EVM→Core (lands in the contract's SPOT balance).
    /// This is what initializes the contract's HyperCore account; any action must
    /// be sent in a LATER block (see design doc).
    function bridgeUsdcToCore(uint256 evmAmount) external onlyKeeper notPaused nonReentrant {
        require(evmAmount > 0, "adapter: zero amount");
        address wallet = HLConstants.coreDepositWallet();
        usdc.forceApprove(wallet, evmAmount);
        emit BridgeToCore(evmAmount);
        ICoreDepositWallet(wallet).deposit(evmAmount, HLConstants.SPOT_DEX);
    }

    /// @notice Step 4 (unwind) — return USDC Core→EVM via sendAsset to the system
    /// address. NOTE: the contract must hold some HYPE on Core to pay transfer gas,
    /// otherwise the action is dropped (silently).
    function bridgeBackToEvm(uint64 weiAmount) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(weiAmount > 0, "adapter: zero amount");
        emit BridgeToEvm(weiAmount);
        _send(
            HLConstants.SEND_ASSET_ACTION,
            abi.encode(
                address(HLConstants.BASE_SYSTEM_ADDRESS + HLConstants.USDC_TOKEN_INDEX),
                address(0),
                HLConstants.SPOT_DEX,
                HLConstants.SPOT_DEX,
                HLConstants.USDC_TOKEN_INDEX,
                weiAmount
            )
        );
    }

    /*//////////////////////// Trading ////////////////////////*/
    /// @notice Step 2 — move USDC spot→perp (or back) on Core. `ntl` is in USDC
    /// perp units (6 decimals; 1 USDC = 1e6).
    function moveUsdcToPerp(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(ntl > 0 && uint256(ntl) <= maxActionUsd6, "adapter: cap");
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, true));
    }

    function moveUsdcToSpot(uint64 ntl) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(ntl > 0 && uint256(ntl) <= maxActionUsd6, "adapter: cap");
        _send(HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, false));
    }

    /// @notice Step 3 — open the short hedge (sell perp). limitPx/sz are 10^8 ×
    /// human value; sz must respect the asset's szDecimals (keeper reads 0x80a).
    function openShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        _order(asset, false, false, limitPx, sz, tif);
    }

    /// @notice Unwind — buy back the short (reduceOnly).
    function closeShort(uint32 asset, uint64 limitPx, uint64 sz, uint8 tif) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        _order(asset, true, true, limitPx, sz, tif);
    }

    function cancelOrderByCloid(uint32 asset, uint128 cloid) external onlyKeeper notPaused coreAccountRequired nonReentrant {
        require(asset == perpAsset, "adapter: wrong asset");
        emit OrderCancelled(asset, cloid);
        _send(HLConstants.CANCEL_ORDER_BY_CLOID_ACTION, abi.encode(asset, cloid));
    }

    /// @dev notional(USDC 6dp) = limitPx * sz / 1e8 / 1e8 * 1e6 = limitPx * sz / 1e10.
    function _order(uint32 asset, bool isBuy, bool reduceOnly, uint64 limitPx, uint64 sz, uint8 tif) internal {
        require(asset == perpAsset, "adapter: wrong asset");
        require(limitPx > 0 && sz > 0, "adapter: zero order");
        require(tif == HLConstants.TIF_ALO || tif == HLConstants.TIF_GTC || tif == HLConstants.TIF_IOC, "adapter: bad tif");
        uint256 notional6 = (uint256(limitPx) * uint256(sz)) / 1e10;
        require(notional6 >= MIN_ORDER_USD6, "adapter: below $10 min notional");
        require(notional6 <= maxActionUsd6, "adapter: cap");
        uint128 cloid = 0;
        emit OrderSent(asset, isBuy, reduceOnly, limitPx, sz, tif, cloid);
        _send(HLConstants.LIMIT_ORDER_ACTION, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    /*//////////////////////// Staking (fee-discount path) ////////////////////////*/
    /// @notice Stake HYPE held on the contract's Core spot balance (action 4).
    /// Owner-gated: policy op, not routine keeper work.
    function stakeHype(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(weiAmount > 0, "adapter: zero amount");
        emit StakeDeposited(weiAmount);
        _send(HLConstants.STAKING_DEPOSIT_ACTION, abi.encode(weiAmount));
    }

    /// @notice Delegate / undelegate staked HYPE to a validator (action 3).
    function delegateHype(address validator, uint64 weiAmount, bool undelegate) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(validator != address(0), "adapter: zero validator");
        emit Delegated(validator, weiAmount, undelegate);
        _send(HLConstants.TOKEN_DELEGATE_ACTION, abi.encode(validator, weiAmount, undelegate));
    }

    /// @notice Withdraw HYPE from staking back to Core spot (action 5).
    function withdrawStake(uint64 weiAmount) external onlyOwner notPaused coreAccountRequired nonReentrant {
        require(weiAmount > 0, "adapter: zero amount");
        emit StakeWithdrawn(weiAmount);
        _send(HLConstants.STAKING_WITHDRAW_ACTION, abi.encode(weiAmount));
    }

    /*//////////////////////// Reads (precompiles) ////////////////////////*/
    function position() public view returns (Position memory) {
        (bool ok, bytes memory ret) = HLConstants.POSITION2_PRECOMPILE.staticcall(abi.encode(address(this), perpAsset));
        require(ok, "adapter: position read failed");
        return abi.decode(ret, (Position));
    }

    function marginSummary() public view returns (AccountMarginSummary memory) {
        (bool ok, bytes memory ret) = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE.staticcall(abi.encode(uint32(0), address(this)));
        require(ok, "adapter: margin read failed");
        return abi.decode(ret, (AccountMarginSummary));
    }

    function withdrawable() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.WITHDRAWABLE_PRECOMPILE.staticcall(abi.encode(address(this)));
        require(ok, "adapter: withdrawable read failed");
        return abi.decode(ret, (uint64));
    }

    function perpSzDecimals() public view returns (uint8) {
        (bool ok, bytes memory ret) = HLConstants.PERP_ASSET_INFO_PRECOMPILE.staticcall(abi.encode(perpAsset));
        require(ok, "adapter: asset info read failed");
        return abi.decode(ret, (PerpAssetInfo)).szDecimals;
    }

    function oraclePx() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.ORACLE_PX_PRECOMPILE.staticcall(abi.encode(perpAsset));
        require(ok, "adapter: oracle read failed");
        return abi.decode(ret, (uint64));
    }

    function markPx() public view returns (uint64) {
        (bool ok, bytes memory ret) = HLConstants.MARK_PX_PRECOMPILE.staticcall(abi.encode(perpAsset));
        require(ok, "adapter: mark read failed");
        return abi.decode(ret, (uint64));
    }

    /*//////////////////////// Internals ////////////////////////*/
    function _coreAccountExists() internal view returns (bool) {
        (bool ok, bytes memory ret) = HLConstants.CORE_USER_EXISTS_PRECOMPILE.staticcall(abi.encode(address(this)));
        require(ok, "adapter: coreUserExists read failed");
        return abi.decode(ret, (CoreUserExists)).exists;
    }

    function _send(uint24 actionId, bytes memory payload) internal {
        bytes memory data = abi.encodePacked(uint8(1), actionId, payload);
        emit ActionSent(actionId, data);
        CORE_WRITER.sendRawAction(data);
    }
}
