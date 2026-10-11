// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FrontierBase} from "./FrontierBase.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal credit-pool interface — THE INTEGRATION SEAM. The concrete
/// venue (a junior-tranche / first-loss credit pool) replaces this at per-name
/// DD; every other line of this adapter is venue-agnostic. DD decides the
/// venue; this file decides the discipline.
interface ICreditPool {
    /// Supply assets, receive pool tokens (junior tranche).
    function supply(uint256 assets, address onBehalf) external returns (uint256 tokens);

    /// Redeem tokens for assets. MAY be partial (lockups/queues are normal
    /// for credit pools) — the adapter caps by the position and treats a
    /// partial fill as success, because the vault measures what arrived.
    function redeem(uint256 tokens, address receiver) external returns (uint256 assets);

    /// Mark-to-model value of `who`'s position in underlying units. Junior
    /// tranches mark DOWN first when the pool takes losses — this read is
    /// where a first-loss event shows up.
    function positionValue(address who) external view returns (uint256);

    /// Pool tokens held by `who` (the redemption unit).
    function positionTokens(address who) external view returns (uint256);
}

/// @title CreditPoolStrategy — the Frontier junior-tranche adapter.
/// @notice First-loss venue class: highest yield in the stack, and the venue
/// can LOSE principal (the junior tranche eats losses before anyone else).
/// The accounting is built for that honestly:
///   - Profit = position growth above the baseline (same delta discipline as
///     MorphoStrategy; supply/recall/sweep all re-baseline).
///   - A position DROP is never fake-smoothed: the baseline moves DOWN, the
///     loss shows in totalAssets() immediately, and `LossObserved` fires so
///     the feed/attestation records it. No negative-profit fantasy.
///   - The Frontier gate (venueCleared + ≤15% of the vault book) guards the
///     supply path; the recall path is never gated — money-out always works.
contract CreditPoolStrategy is FrontierBase {
    using SafeERC20 for IERC20;

    ICreditPool public immutable pool;

    uint256 public bufferBps; // idle cushion kept back (recall room)
    uint256 public lastHarvestPosition; // baseline after last supply/recall/sweep
    uint256 public totalSupplied; // lifetime supplied (stats only)

    event Supplied(uint256 amount, uint256 tokens);
    event Recalled(uint256 requested, uint256 returned);
    event LossObserved(uint256 baseline, uint256 mark);
    event BufferSet(uint256 bps);

    constructor(
        address _underlying,
        address initialOwner,
        address _pool
    ) FrontierBase(_underlying, initialOwner, "CreditPool") {
        require(_pool != address(0), "CreditPool: zero pool");
        pool = ICreditPool(_pool);
    }

    function name() external view override returns (string memory) {
        return "CreditPool";
    }

    function positionValue() public view returns (uint256) {
        return pool.positionValue(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        return underlying.balanceOf(address(this)) + positionValue();
    }

    /// @notice Keeper/owner: supply the idle balance (above the buffer) into
    /// the pool. Gated: DD-cleared + per-name cap, checked BEFORE any token
    /// moves. The vault must be wired (`setVault`) or the cap is unverifiable
    /// and supply is impossible — fail closed.
    function deploy() external nonReentrant {
        require(msg.sender == owner() || msg.sender == keeper, "CreditPool: not keeper");
        require(isActive, "CreditPool: inactive");
        uint256 bal = underlying.balanceOf(address(this));
        uint256 buffer = (bal * bufferBps) / 10000;
        uint256 amount = bal > buffer ? bal - buffer : 0;
        require(amount > 0, "CreditPool: nothing to supply");
        _frontierGate(); // reverts NotCleared / CapExceeded / CapUnverifiable
        underlying.forceApprove(address(pool), amount);
        uint256 tokens = pool.supply(amount, address(this));
        totalSupplied += amount;
        lastHarvestPosition = positionValue(); // new principal is never yield
        emit Supplied(amount, tokens);
    }

    /// @notice Vault-only: return funds, unwinding the pool position as needed.
    /// NOT gated — a locked frontier venue must never trap the vault's money.
    /// Never reverts for pool illiquidity: partial redemption is fine, the
    /// vault measures what actually arrived.
    function recall(uint256 amount) external override nonReentrant {
        require(msg.sender == vault, "CreditPool: not vault");
        if (amount == 0) return;
        uint256 idle = underlying.balanceOf(address(this));
        if (idle < amount) {
            uint256 need = amount - idle;
            uint256 pv = positionValue();
            if (need > pv) need = pv;
            if (need > 0) _unwind(need);
        }
        uint256 bal = underlying.balanceOf(address(this));
        uint256 sent = amount > bal ? bal : amount;
        if (sent > 0) {
            lastHarvestPosition = positionValue(); // principal leaving ≠ yield
            underlying.safeTransfer(vault, sent);
        }
        emit Recalled(amount, sent);
    }

    /// @dev Redeem `need`-worth of position (ceil by tokens, capped by both
    /// the position and our token balance). try/catch: a locked/illiquid pool
    /// = partial no-op (the async/queue reality of credit venues).
    function _unwind(uint256 need) internal {
        uint256 pv = positionValue();
        uint256 tokens = pool.positionTokens(address(this));
        if (pv == 0 || tokens == 0) return;
        uint256 tokensOut = (need * tokens + pv - 1) / pv; // ceil
        if (tokensOut > tokens) tokensOut = tokens;
        try pool.redeem(tokensOut, address(this)) {} catch {}
    }

    /// @notice Vault-only sweep. Junior-tranche honest accounting:
    /// growth above baseline = profit (swept, buffer-aware); a DROP below
    /// baseline = the pool took first losses — re-baseline DOWN, emit
    /// LossObserved, book nothing. The loss is already visible in
    /// totalAssets() (the mark is the mark).
    function _doHarvest() internal override returns (uint256 profit) {
        if (!isActive) revert("CreditPool: inactive");
        if (msg.sender != vault) return 0; // keeper/owner calls just sync
        uint256 pv = positionValue();
        if (pv < lastHarvestPosition) {
            emit LossObserved(lastHarvestPosition, pv);
            lastHarvestPosition = pv;
            return 0;
        }
        if (pv == lastHarvestPosition) return 0;
        uint256 accrued = pv - lastHarvestPosition;
        uint256 bal = underlying.balanceOf(address(this));
        if (bal < accrued) {
            _unwind(accrued - bal);
            bal = underlying.balanceOf(address(this));
        }
        uint256 buffer = (bal * bufferBps) / 10000;
        uint256 sweepable = bal > buffer ? bal - buffer : 0;
        uint256 sweep = accrued < sweepable ? accrued : sweepable;
        if (sweep == 0) return 0; // yield stays claimable next sweep
        lastHarvestPosition = positionValue();
        underlying.safeTransfer(vault, sweep);
        return sweep;
    }

    function setBufferBps(uint256 bufferBps_) external onlyOwner nonReentrant {
        require(bufferBps_ <= 5000, "CreditPool: buffer too high");
        bufferBps = bufferBps_;
        emit BufferSet(bufferBps_);
    }
}
