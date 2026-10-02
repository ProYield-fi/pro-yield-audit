// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PYDFunder — USDC fees → PYD reward streams (the conversion step)
/// @notice The missing link between fee/referral revenue and PYD staking:
/// collected USDC fees are converted into PYD and streamed to PYDStaking as
/// reward windows — automatically, in capped slices, without any APY promise.
///
/// WHY THIS EXISTS (the honest-fee discipline): PYDStaking.fundRewards needs
/// PYD. Today fees arrive as USDC and nothing converts them — referral
/// revenue, vault perf fees and recycling income pile up in FeeDistributor
/// with no path to PYD demand. This contract closes that loop: the owner/
/// keeper routes USDC in (from the FD recycle), and `topUp()` converts up to
/// `maxConvertUsd6` per call into PYD via a configurable swapper, then funds
/// a stream on PYDStaking.
///
/// WHY A SWAPPER INTERFACE (not a hardcoded router): the DEX landscape isn't
/// decided (HyperEVM AMM vs HyperCore spot). The swapper is a separate,
/// minimal contract the owner sets — this keeps THIS contract's audit surface
/// tiny and lets the swap venue evolve without redeploying.
///
/// HONEST ACCOUNTING:
/// - Never promises APY: the stream size is whatever the conversion yielded.
/// - Every conversion is event-logged (USDC in, PYD out, stream funded).
/// - `maxConvertUsd6` caps per-call exposure; `minConvertUsd6` skips dust.
/// - The owner can pause; all state changes precede external calls.
contract PYDFunder is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IPYDStaking public immutable staking;
    ISwapper public swapper; // set by owner; swaps USDC -> PYD

    uint256 public maxConvertUsd6 = 1000e6;  // per-call cap
    uint256 public minConvertUsd6 = 10e6;    // dust skip
    bool public paused;

    /// AUDIT F-8: `rewardRate = amount / duration` FLOORS, so an absurdly long
    /// duration drives the rate to 0 and strands every PYD in the stream
    /// permanently (unrecoverable — `leftover` is derived from the same zero
    /// rate). The floor is deliberately ONE DAY, not 30: a 1-day stream is a
    /// legitimate cadence (and what the test suite uses), so the bound targets
    /// only the freeze. The ceiling stops the mirror attack (dumping 100% of the
    /// pot in a single block). A rate floor is enforced at the call site below.
    uint256 public constant MIN_STREAM_DURATION = 1 days;
    uint256 public constant MAX_STREAM_DURATION = 365 days;
    /// @notice Minimum tokens-per-second a stream must pay out, so `amount /
    /// duration` can never round to zero for any realistic input size.
    uint256 public constant MIN_REWARD_RATE = 1;

    error PYDFunder__ZeroAmount();
    error PYDFunder__BelowDust();
    error PYDFunder__Cap();
    error PYDFunder__ZeroAddresses();
    error PYDFunder__Paused();
    error PYDFunder__ZeroSwapper();
    error PYDFunder__NoOutput();
    error PYDFunder__DurationTooShort();
    error PYDFunder__DurationTooLong();
    error PYDFunder__ZeroRate();

    event UsdcReceived(uint256 total);
    event Converted(address indexed swapper, uint256 usdcIn, uint256 pydOut);
    event StreamFunded(uint256 pydAmount, uint256 duration);
    event MaxConvertSet(uint256 cap);
    event PausedSet(bool paused);
    event SwapperSet(address indexed swapper);

    constructor(address _usdc, address _staking, address initialOwner) Ownable(initialOwner) {
        if (_usdc == address(0) || _staking == address(0)) revert PYDFunder__ZeroAddresses();
        usdc = IERC20(_usdc);
        staking = IPYDStaking(_staking);
    }

    /*//////////////////////// Admin ////////////////////////*/
    function setSwapper(address s) external onlyOwner {
        if (s == address(0)) revert PYDFunder__ZeroSwapper();
        swapper = ISwapper(s);
        emit SwapperSet(s);
    }

    function setMaxConvertUsd6(uint256 cap) external onlyOwner {
        maxConvertUsd6 = cap;
        emit MaxConvertSet(cap);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    /// @notice Setup: the staking owner transfers PYDStaking ownership to
    /// this contract (OZ v5 Ownable is one-step: transferOwnership IS final)
    /// so `topUp` can fund reward streams directly. Without this,
    /// fundRewards (onlyOwner) would revert for the funder.

    /*//////////////////////// Reconciliation ////////////////////////*/
    /// @notice Track USDC routed in from the recycler/FD (plain transfers).
    /// Anyone may call — mirrors FD.receiveFees.
    function receiveUsdc() external {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) emit UsdcReceived(bal);
    }

    /*//////////////////////// Conversion + stream funding ////////////////////////*/
    /// @notice Convert up to `amount6` USDC into PYD and fund a reward stream.
    /// Permissionless above the dust floor (keeper work is liveness, not
    /// trust): the caps + swapper hold policy.
    ///
    /// Flow: USDC -> swapper -> PYD -> staking.fundRewards(pyd, duration).
    /// The stream size is whatever the swap yielded — never a modeled number.
    ///
    /// AUDIT F-8 FIX. `duration` was forwarded unvalidated into `fundRewards`,
    /// where `rewardRate = amount / duration` FLOORS. A caller passing an absurd
    /// duration (e.g. `1e27` seconds) drove the rate to 0, so the converted PYD
    /// became permanently unclaimable — and a later top-up could not rescue it,
    /// because `leftover` is computed as `remaining * rate = 0`. Anyone could
    /// freeze the reward stream for free. The mirror attack (`duration = 1`)
    /// released 100% instantly. The bounds below make both impossible while
    /// keeping the call permissionless.
    function topUp(uint256 amount6, uint256 duration) external nonReentrant {
        if (paused) revert PYDFunder__Paused();
        if (address(swapper) == address(0)) revert PYDFunder__ZeroSwapper();
        if (amount6 == 0) revert PYDFunder__ZeroAmount();
        if (amount6 < minConvertUsd6) revert PYDFunder__BelowDust();
        // Bound the stream length: too long floors rewardRate to zero and strands
        // the PYD forever; too short dumps the whole pot at once.
        if (duration < MIN_STREAM_DURATION) revert PYDFunder__DurationTooShort();
        if (duration > MAX_STREAM_DURATION) revert PYDFunder__DurationTooLong();
        uint256 cap = amount6 > maxConvertUsd6 ? maxConvertUsd6 : amount6;

        uint256 balance = usdc.balanceOf(address(this));
        if (cap > balance) cap = balance;
        if (cap < minConvertUsd6) revert PYDFunder__BelowDust();

        // 1) Approve + swap. Output is verified by BALANCE DELTA (the return
        // value is advisory — a malicious swapper can lie; balances can't).
        usdc.forceApprove(address(swapper), cap);
        uint256 pydBefore = IERC20(staking.pyd()).balanceOf(address(this));
        uint256 pydOut = 0;
        // Effects-before-interactions discipline: events emit before the
        // external call (tx atomicity keeps ordering equivalent).
        emit Converted(address(swapper), cap, 0);
        uint256 got = swapper.swap(address(usdc), address(staking.pyd()), cap, 0);
        pydOut = IERC20(staking.pyd()).balanceOf(address(this)) - pydBefore;
        if (pydOut == 0) revert PYDFunder__NoOutput();
        // AUDIT F-8: refuse a stream whose rate would floor to zero. This is the
        // precise form of the freeze bug — `fundRewards` computes
        // `rewardRate = amount / duration`, and a 0 rate makes the PYD
        // unclaimable forever (a later top-up cannot rescue it, because
        // `leftover` is derived from the same zero rate). Checking the actual
        // output here is what the duration bounds alone cannot guarantee.
        if (pydOut / duration < MIN_REWARD_RATE) revert PYDFunder__ZeroRate();
        // AUDIT FIX: the pre-call emit above can only know 0, so the real figure
        // was never logged anywhere — an off-chain consumer reading `Converted`
        // always saw pydOut == 0 and could not reconcile a conversion. Emit the
        // MEASURED output now that the balance delta has been taken.
        emit Converted(address(swapper), cap, pydOut);
        // Revoke the allowance IMMEDIATELY after the swap — the swapper must
        // never hold a live approval on this contract's USDC.
        usdc.forceApprove(address(swapper), 0);

        // 2) Fund the stream (staking pulls PYD from this contract)
        IERC20(staking.pyd()).forceApprove(address(staking), pydOut);
        staking.fundRewards(pydOut, duration);

        emit StreamFunded(pydOut, duration);
    }

    /// @notice Convenience read: how much USDC is awaiting conversion.
    function pendingUsdc() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

/*//////////////////////// Minimal interfaces ////////////////////////*/
interface IPYDStaking {
    function pyd() external view returns (address);
    function fundRewards(uint256 amount, uint256 duration) external;
}

/// @dev Minimal swap interface — the owner-set swapper implements this.
/// `minOut=0` is acceptable HERE because the output is verified by balance
/// delta and the stream size is whatever arrived (no modeled expectation to
/// violate). A production swapper should still enforce its own slippage.
interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256);
}
