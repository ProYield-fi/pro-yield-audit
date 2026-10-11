// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal ERC-4626 surface used by the sUSD3 executor.
interface IERC4626Min {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice The sUSD3 cooldown surface (3Jane ISUSD3 — verified live 2026-10-04).
interface ISUSD3Cooldown {
    function startCooldown(uint256 shares) external;
    function cancelCooldown() external;
    function cooldowns(address user)
        external
        view
        returns (uint64 cooldownEnd, uint64 windowEnd, uint128 shares);
}

interface ITokenMessengerV2BurnSusd {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @title SUSD3Executor — Ethereum-side executor for the Frontier sUSD3 sleeve.
///
/// Sibling of PTSleeveEthExecutor (contracts/ethi/PTSleeveEthExecutor.sol):
/// same trust model, same ops surface. The venue difference is the LIFECYCLE:
/// sUSD3's exit is asynchronous — `startCooldown(shares)` (the venue's own
/// 30-day cooldown, currently no entry lock) then a redemption inside the
/// withdrawal window. The executor therefore exposes the cooldown lifecycle
/// as separate ops steps; the HyperEVM strategy stays the only bridge
/// counterparty.
///
/// Capital path in :  HyperEVM vault → strategy → CCTP burn → THIS
///   → ops `enter`: USDC → USD3 (ERC-4626) → sUSD3 (ERC-4626 over USD3)
/// Position      :  sUSD3 shares held HERE (junior/first-loss tranche)
/// Capital path out: ops `beginExit` → wait ≥ cooldownDuration (venue-enforced)
///   → ops `completeExit`: sUSD3 → USD3 → USDC → ops `bridgeBack`
///   → CCTP standard transfer → the HyperEVM strategy (immutable recipient)
///
/// Trust model (identical to the PT executors):
///  - `ops` (keeper key) can ONLY: wrap capital into the two configured
///    ERC-4626 vaults, start/cancel cooldowns on sUSD3, redeem cooldown-
///    eligible shares back down to USDC, and burn USDC to the IMMUTABLE
///    HyperEVM strategy. It can never move funds anywhere else and can never
///    change configuration.
///  - `owner` (the 2/3 treasury Safe) holds the one-time return-destination
///    correction (bootstrap) and the rescue hatch.
///  - Every leg takes min-out bounds from the caller, re-asserted here.
///  - The junior tranche can LOSE value (first loss) — this contract never
///    hides that: balances are what they are; the strategy's attestation
///    records the mark.
contract SUSD3Executor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC4626Min public immutable usd3; // senior vault (ERC-4626 over USDC)
    IERC4626Min public immutable susd3; // junior vault (ERC-4626 over USD3)
    ISUSD3Cooldown public immutable cooldownCtl; // = susd3 (typed for clarity)
    ITokenMessengerV2BurnSusd public immutable tokenMessenger;
    uint32 public constant HYPEREVM_DOMAIN = 19;

    /// @dev The HyperEVM strategy address (bytes32) that bridgeBack mints to.
    /// One-time owner correction before any activity, then locked (same
    /// bootstrap pattern as the PT executors).
    bytes32 public strategyReturn;
    bool public returnConfirmed;

    address public ops;

    uint256 public enterCount;
    uint256 public exitCount;
    uint256 public bridgeBackCount;

    event OpsSet(address indexed ops);
    event Entered(uint256 usdcIn, uint256 usd3Out, uint256 susd3Out);
    event CooldownStarted(uint256 shares);
    event CooldownCancelled();
    event Exited(uint256 susd3Shares, uint256 usd3Out, uint256 usdcOut);
    event BridgedBack(uint256 amount, uint256 maxFee);
    event StrategyReturnConfirmed(address indexed strategy);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error SUSD3E__NotOps();
    error SUSD3E__ZeroAddr();
    error SUSD3E__BadAmount();
    error SUSD3E__Slippage();
    error SUSD3E__AlreadyConfirmed();
    error SUSD3E__TooLate();

    modifier onlyOps() {
        if (msg.sender != ops) revert SUSD3E__NotOps();
        _;
    }

    constructor(
        address _usdc,
        address _usd3,
        address _susd3,
        address _tokenMessenger,
        address _strategyReturn,
        address _ops,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            _usdc == address(0) || _usd3 == address(0) || _susd3 == address(0) || _tokenMessenger == address(0)
                || _strategyReturn == address(0) || _ops == address(0)
        ) revert SUSD3E__ZeroAddr();
        // the junior vault's underlying MUST be the senior vault (venue shape)
        if (IERC4626Min(_susd3).asset() != _usd3) revert SUSD3E__ZeroAddr();
        usdc = IERC20(_usdc);
        usd3 = IERC4626Min(_usd3);
        susd3 = IERC4626Min(_susd3);
        cooldownCtl = ISUSD3Cooldown(_susd3);
        tokenMessenger = ITokenMessengerV2BurnSusd(_tokenMessenger);
        strategyReturn = bytes32(uint256(uint160(_strategyReturn)));
        ops = _ops;
    }

    function setOps(address _ops) external onlyOwner {
        if (_ops == address(0)) revert SUSD3E__ZeroAddr();
        ops = _ops;
        emit OpsSet(_ops);
    }

    /// @notice One-time correction of the return destination (bootstrap), then
    /// locked forever — and refused as soon as ANY activity has happened.
    function confirmStrategyReturn(address _strategy) external onlyOwner {
        if (returnConfirmed) revert SUSD3E__AlreadyConfirmed();
        if (enterCount != 0 || exitCount != 0 || bridgeBackCount != 0) revert SUSD3E__TooLate();
        if (_strategy == address(0)) revert SUSD3E__ZeroAddr();
        strategyReturn = bytes32(uint256(uint160(_strategy)));
        returnConfirmed = true;
        emit StrategyReturnConfirmed(_strategy);
    }

    /// @notice Ops: wrap idle USDC into the position — USDC → USD3 → sUSD3.
    /// Both legs are ERC-4626 deposits; the min-out bounds are re-asserted
    /// here against the actual amounts received (balance-delta, never the
    /// venue's claimed return).
    function enter(uint256 usdcAmount, uint256 minUsd3Out, uint256 minSusd3Out)
        external
        onlyOps
        nonReentrant
        returns (uint256 usd3Out, uint256 susd3Out)
    {
        if (usdcAmount == 0 || usdcAmount > usdc.balanceOf(address(this))) revert SUSD3E__BadAmount();
        // Leg 1: USDC -> USD3.
        usdc.forceApprove(address(usd3), usdcAmount);
        uint256 usd3Before = usd3.balanceOf(address(this));
        usd3.deposit(usdcAmount, address(this));
        usd3Out = usd3.balanceOf(address(this)) - usd3Before;
        if (usd3Out < minUsd3Out) revert SUSD3E__Slippage();
        // Leg 2: USD3 -> sUSD3 (stake into the junior tranche).
        IERC20(address(usd3)).forceApprove(address(susd3), usd3Out);
        uint256 sBefore = susd3.balanceOf(address(this));
        susd3.deposit(usd3Out, address(this));
        susd3Out = susd3.balanceOf(address(this)) - sBefore;
        if (susd3Out < minSusd3Out) revert SUSD3E__Slippage();
        enterCount += 1;
        emit Entered(usdcAmount, usd3Out, susd3Out);
    }

    /// @notice Ops: start the venue's cooldown on `shares` (the exit door's
    /// first turn — the venue itself enforces its lock/cooldown timing).
    function beginExit(uint256 susd3Shares) external onlyOps nonReentrant {
        if (susd3Shares == 0 || susd3Shares > susd3.balanceOf(address(this))) revert SUSD3E__BadAmount();
        cooldownCtl.startCooldown(susd3Shares);
        emit CooldownStarted(susd3Shares);
    }

    /// @notice Ops: cancel a pending cooldown (shares return to the freely
    /// holdable position — used if the plan changes during the wait).
    function cancelExit() external onlyOps nonReentrant {
        cooldownCtl.cancelCooldown();
        emit CooldownCancelled();
    }

    /// @notice Ops: redeem cooldown-ELIGIBLE sUSD3 shares down to USDC.
    /// Two legs, both partial-tolerant by design (the vault measures what
    /// arrived): sUSD3 redeem is capped by `maxRedeem` (0 before the cooldown
    /// ends — the caller checks `exitableShares()` first), the USD3 → USDC
    /// leg is capped by USD3's own `maxWithdraw` (tranche-ratio liquidity).
    function completeExit(uint256 susd3Shares, uint256 minUsd3Out, uint256 minUsdcOut)
        external
        onlyOps
        nonReentrant
        returns (uint256 usd3Out, uint256 usdcOut)
    {
        if (susd3Shares == 0) revert SUSD3E__BadAmount();
        // Leg 1: sUSD3 -> USD3, capped by the venue's cooldown-eligible max.
        uint256 eligible = susd3.maxRedeem(address(this));
        uint256 shares = susd3Shares > eligible ? eligible : susd3Shares;
        if (shares == 0) revert SUSD3E__BadAmount(); // cooldown not finished yet
        uint256 usd3Before = usd3.balanceOf(address(this));
        susd3.redeem(shares, address(this), address(this));
        usd3Out = usd3.balanceOf(address(this)) - usd3Before;
        if (usd3Out < minUsd3Out) revert SUSD3E__Slippage();
        // Leg 2: USD3 -> USDC, capped by USD3's own withdrawal limit
        // (tranche-ratio liquidity — partial is normal and fine).
        uint256 usd3Have = usd3.balanceOf(address(this));
        uint256 withdrawable = usd3.maxWithdraw(address(this));
        uint256 usd3Amt = usd3Have > withdrawable ? withdrawable : usd3Have;
        usdcOut = 0;
        if (usd3Amt > 0) {
            uint256 usdcBefore = usdc.balanceOf(address(this));
            usd3.withdraw(usd3Amt, address(this), address(this));
            usdcOut = usdc.balanceOf(address(this)) - usdcBefore;
        }
        if (usdcOut < minUsdcOut) revert SUSD3E__Slippage();
        exitCount += 1;
        emit Exited(shares, usd3Out, usdcOut);
    }

    /// @notice Ops: convert held USD3 → USDC (the senior leg alone — used
    /// when USD3 arrived from an earlier sUSD3 redemption but the venue's
    /// USDC liquidity was momentarily out; amortizing receivables refill it).
    function unwindUsd3(uint256 minUsdcOut) external onlyOps nonReentrant returns (uint256 usdcOut) {
        uint256 usd3Have = usd3.balanceOf(address(this));
        uint256 withdrawable = usd3.maxWithdraw(address(this));
        uint256 usd3Amt = usd3Have > withdrawable ? withdrawable : usd3Have;
        if (usd3Amt == 0) revert SUSD3E__BadAmount();
        uint256 usdcBefore = usdc.balanceOf(address(this));
        usd3.withdraw(usd3Amt, address(this), address(this));
        usdcOut = usdc.balanceOf(address(this)) - usdcBefore;
        if (usdcOut < minUsdcOut) revert SUSD3E__Slippage();
        emit Exited(0, usd3Amt, usdcOut);
    }

    /// @notice Ops: burn USDC back to the HyperEVM strategy via CCTP
    /// (standard transfer, fee-free today, destination IMMUTABLE).
    function bridgeBack(uint256 amount, uint256 maxFee) external onlyOps nonReentrant {
        if (amount == 0 || amount > usdc.balanceOf(address(this))) revert SUSD3E__BadAmount();
        usdc.forceApprove(address(tokenMessenger), amount);
        tokenMessenger.depositForBurn(
            amount, HYPEREVM_DOMAIN, strategyReturn, address(usdc), bytes32(0), maxFee, 2000
        );
        bridgeBackCount += 1;
        emit BridgedBack(amount, maxFee);
    }

    /// @notice Owner (2/3 Safe) rescue hatch — ops can NOT call this.
    function ownerRescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert SUSD3E__ZeroAddr();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ----------------------------------------------------------------- views

    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function usd3Balance() external view returns (uint256) {
        return usd3.balanceOf(address(this));
    }

    function susd3Balance() external view returns (uint256) {
        return susd3.balanceOf(address(this));
    }

    /// @notice sUSD3 shares currently redeemable (cooldown finished, inside
    /// the window) — ops checks this before completeExit.
    function exitableShares() external view returns (uint256) {
        return susd3.maxRedeem(address(this));
    }

    /// @notice Cooldown status passthrough (cooldownEnd, windowEnd, shares).
    function cooldownStatus()
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        (uint64 ce, uint64 we, uint128 sh) = cooldownCtl.cooldowns(address(this));
        return (ce, we, sh);
    }

    /// @notice USDC value of the whole position (sUSD3 → USD3 → USDC mark).
    /// Read-only double-hop mark; never trust it as a guarantee — the venue
    /// marks down first (that is what junior means).
    function positionValueUsd6() external view returns (uint256) {
        uint256 susd3Shares = susd3.balanceOf(address(this));
        if (susd3Shares == 0) return usdc.balanceOf(address(this));
        uint256 usd3Amt = susd3.convertToAssets(susd3Shares);
        uint256 usdcAmt = usd3.convertToAssets(usd3Amt);
        return usdc.balanceOf(address(this)) + usdcAmt;
    }
}
