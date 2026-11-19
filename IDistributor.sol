// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @dev Common interface of BossDistributor, MinerDistributor and RevenueSplitter (ETH only).
interface IDistributor {
    function depositETH(string calldata ref) external payable;
}

interface IBossDistributor is IDistributor {
    function BOSSES() external view returns (address);
}

interface ISupply {
    function totalSupply() external view returns (uint256);
}
