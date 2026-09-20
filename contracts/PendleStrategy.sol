// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PendleStrategy is BaseStrategy {
    address public pendleMarket;
    uint256 public immutable maturity;

    constructor(address _underlying, address initialOwner, address _pendleMarket)
        BaseStrategy(_underlying, initialOwner, "Pendle")
    {
        require(_pendleMarket != address(0), "Pendle: zero market");
        pendleMarket = _pendleMarket;
        maturity = block.timestamp + 365 days;
    }

    function name() external view override returns (string memory) {
        return "Pendle";
    }

    /// @notice Accept native venue settlements (mirrors DeltaNeutral). Without
    /// this, _claimRewards's `address(this).balance > 0` branch was UNREACHABLE
    /// dead code — found by the round-4 post-maturity claim test.
    receive() external payable {}

    function setMarket(address market) external onlyOwner nonReentrant {
        require(market != address(0), "Pendle: zero market");
        pendleMarket = market;
    }

    function harvest() external override nonReentrant {
        if (block.timestamp > maturity && pendleMarket != address(0)) {
            _claimRewards();
        }
    }

    /// @notice BUGFIX (found by time-warp integration test): this was marked
    /// nonReentrant while its ONLY caller (harvest) also holds the lock —
    /// after maturity every harvest reverted with ReentrancyGuardReentrantCall,
    /// bricking the whole vault harvest for a year. Internal-only helper:
    /// the entry-point lock is sufficient. Auth extended to the vault so
    /// ProYieldVault.harvest's sweep loop can claim on behalf of depositors.
    function _claimRewards() internal {
        if (address(this).balance > 0 && (msg.sender == owner() || msg.sender == vault)) {
            // slither-disable-next-line low-level-calls
            (bool success, ) = pendleMarket.call{value: address(this).balance}("");
            require(success, "Pendle: transfer failed");
        }
    }

}
