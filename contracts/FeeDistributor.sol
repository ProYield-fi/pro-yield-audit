// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FeeDistributor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public immutable pyd;
    address[] public strategies;
    mapping(address => uint256) public pendingFees;
    mapping(address => uint256) public claimed;
    uint256 public totalFees;

    constructor(address _pyd) Ownable(msg.sender) {
        pyd = IERC20(_pyd);
    }

    function name() external view returns (string memory) {
        return "FeeDistributor";
    }

    function addStrategy(address strategy) external onlyOwner nonReentrant {
        require(strategy != address(0), "FeeDistributor: zero strategy");
        strategies.push(strategy);
    }

    function distribute() external onlyOwner nonReentrant {
        _distributeStrategy(msg.sender);
    }

    function distributeTo(address strategy) external onlyOwner nonReentrant {
        require(strategy != address(0), "FeeDistributor: zero strategy");
        _distributeStrategy(strategy);
    }

    function _distributeStrategy(address strategy) internal {
        uint256 fee = pendingFees[strategy];
        if (fee > 0) {
            claimed[strategy] += fee;
            totalFees -= fee;
            pendingFees[strategy] = 0;
            pyd.safeTransfer(strategy, fee);
        }
    }

    function withdrawFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        require(amount > 0, "FeeDistributor: no fees");
        pendingFees[msg.sender] = 0;
        pyd.safeTransfer(msg.sender, amount);
    }
}
