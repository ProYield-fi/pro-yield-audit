// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
using SafeERC20 for IERC20;
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
using SafeERC20 for IERC20;

contract DeltaNeutralStrategy is BaseStrategy {
    address public shortPosition;
    uint256 public delta;
    uint256 public fundingRate;
    uint256 public lastUpdate;
    mapping(address => uint256) public positions;
    address public oracle;

    constructor(address _underlying, address _owner, address _short, address _oracle)
        BaseStrategy(_underlying, _owner, "DeltaNeutral")
    {
        shortPosition = _short;
        oracle = _oracle;
    }

    function name() external view override returns (string memory) {
        return "DeltaNeutral";
    }

    function setShortPosition(address _short) external onlyOwner nonReentrant {
        shortPosition = _short;
    }

    function setOracle(address _oracle) external onlyOwner nonReentrant {
        oracle = _oracle;
    }

    function openPosition(uint256 size) external onlyOwner nonReentrant {
        positions[msg.sender] = size;
        delta += size;
    }

    function closePosition() external onlyOwner nonReentrant {
        uint256 size = positions[msg.sender];
        delta -= size;
        positions[msg.sender] = 0;
    }

    function updateFunding() external onlyOwner nonReentrant {
        fundingRate = _fetchFundingRate();
        lastUpdate = block.timestamp;
    }

    function _fetchFundingRate() internal view returns (uint256) {
        // Oracle-based funding rate — currently returns 0 for testnet
        if (oracle == address(0)) return 0;
        // In production: return Oracle(oracle).getFundingRate();
        return 0;
    }

    function _doHarvest() internal override returns (uint256) {
        uint256 profit = 0;
        if (shortPosition != address(0) && delta > 0) {
            uint256 balance = address(this).balance;
            if (balance > 0) {
                (bool success, ) = shortPosition.call{value: balance}("");
                require(success, "DeltaNeutral: transfer failed");
                profit = balance;
            }
        }
        return profit;
    }
}
