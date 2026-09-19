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

    function setMarket(address market) external onlyOwner nonReentrant {
        require(market != address(0), "Pendle: zero market");
        pendleMarket = market;
    }

    function harvest() external override nonReentrant {
        if (block.timestamp > maturity && pendleMarket != address(0)) {
            _claimRewards();
        }
    }

    function _claimRewards() internal nonReentrant {
        if (address(this).balance > 0 && msg.sender == owner()) {
            // slither-disable-next-line low-level-calls
            (bool success, ) = pendleMarket.call{value: address(this).balance}("");
            require(success, "Pendle: transfer failed");
        }
    }

}
