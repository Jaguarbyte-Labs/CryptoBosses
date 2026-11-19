// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IDistributor, IBossDistributor, ISupply} from "./IDistributor.sol";

/**
 * @title RevenueSplitter (ETH only since 2026-11-15)
 * @notice Single entry point for the CryptoBosses ecosystem revenue. Splits every ETH deposit with
 *         percentages fixed in the code:
 *
 *           51% --> Bosses   (/ 10,000 FIXED: each Boss receives 0.0051% of revenue)
 *            4% --> Miners   (CryptoMiners; / Miners existing at the deposit)
 *           45% --> TREASURY (+ the share of Bosses not minted yet)
 *
 * Fixed Boss divisor: the splitter sends the BossDistributor only the share of the Bosses that exist
 * (51% x supply / 10,000); the distributor divides it by the same supply, so each Boss receives
 * exactly 1/10,000 of 51%, whether there are 2 or 10,000 Bosses. The rest goes to the treasury.
 * Consequences: minting a Boss before a deposit does not increase anyone's share (no front-running),
 * and minting the reserve does not dilute existing holders.
 *
 * Guarantees: no owner, no admin, immutable percentages and destinations, nothing is retained here.
 * ETH sent directly (receive) is split too. Note: contracts that send with `.transfer`/`.send`
 * (2300 gas) will fail; use depositETH. Idle balance (e.g. third-party selfdestruct): flush().
 */
contract RevenueSplitter is IDistributor, ReentrancyGuard {
    uint256 public constant BPS = 1e4;
    /// @notice 51% for the 10,000 Bosses.
    uint256 public constant BOSS_BPS = 5_100;
    /// @notice 4% for the CryptoMiners.
    uint256 public constant MINER_BPS = 400;
    /// @notice 45% for the treasury (plus the share of unminted Bosses).
    uint256 public constant TREASURY_BPS = BPS - BOSS_BPS - MINER_BPS;
    /// @notice Fixed Boss divisor (MAX_BOSSES of CryptoBosses).
    uint256 public constant MAX_BOSSES = 1e4;

    IBossDistributor public immutable BOSS_DISTRIBUTOR;
    IDistributor public immutable MINER_DISTRIBUTOR;
    ISupply public immutable BOSSES;
    address payable public immutable TREASURY;

    event Split(address indexed from, uint256 bossSupply, uint256 toBosses, uint256 toMiners, uint256 toTreasury, string ref);

    error ZeroAmount();

    /// @param bossDistributor  BossDistributor address.
    /// @param minerDistributor MinerDistributor address (CryptoMiners.DISTRIBUTOR()).
    /// @param bosses           CryptoBosses (checked against bossDistributor.BOSSES()).
    /// @param treasury         Treasury (recommended: Safe multisig). Immutable.
    constructor(address bossDistributor, address minerDistributor, address bosses, address payable treasury) {
        require(bossDistributor != address(0) && minerDistributor != address(0) && bosses != address(0) && treasury != address(0), "zero address");
        require(treasury != bossDistributor && treasury != minerDistributor, "treasury = distributor");
        BOSS_DISTRIBUTOR = IBossDistributor(bossDistributor);
        MINER_DISTRIBUTOR = IDistributor(minerDistributor);
        BOSSES = ISupply(bosses);
        TREASURY = treasury;
        // checked only after storing everything (no write after an external call)
        require(IBossDistributor(bossDistributor).BOSSES() == bosses, "BOSSES differs from distributor");
    }

    // Accepting ETH from anyone is the purpose of the contract: ETH only leaves to the two
    // distributors and the treasury, immutable addresses fixed at deployment.
    // aderyn-ignore-next-line(eth-send-unchecked-address)
    receive() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _split(msg.value, "");
    }

    // Same reason as receive: immutable destinations, not chosen by the caller.
    // aderyn-ignore-next-line(eth-send-unchecked-address)
    function depositETH(string calldata ref) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _split(msg.value, ref);
    }

    /// @notice Splits any ETH idle here (that arrived without receive/depositETH).
    // aderyn-ignore-next-line(eth-send-unchecked-address)
    function flush() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance < 1) revert ZeroAmount();
        _split(balance, "flush");
    }

    /// @notice Preview of the split of `amount` with the current Boss supply.
    function preview(uint256 amount) external view returns (uint256 bossSupply, uint256 toBosses, uint256 toMiners, uint256 toTreasury) {
        return _shares(amount);
    }

    /// @dev amount > 0 guaranteed by the caller.
    function _split(uint256 amount, string memory ref) private {
        (uint256 supply, uint256 toBosses, uint256 toMiners, uint256 toTreasury) = _shares(amount);
        emit Split(msg.sender, supply, toBosses, toMiners, toTreasury, ref);
        if (toBosses > 0) BOSS_DISTRIBUTOR.depositETH{value: toBosses}(ref);
        if (toMiners > 0) MINER_DISTRIBUTOR.depositETH{value: toMiners}(ref);
        if (toTreasury > 0) Address.sendValue(TREASURY, toTreasury);
    }

    /// @dev Bosses: 51% x min(supply, 10,000) / 10,000. Miners: 4%. Treasury: the rest
    ///      (45% + unminted share + rounding), so nothing is retained.
    function _shares(uint256 amount) private view returns (uint256 supply, uint256 toBosses, uint256 toMiners, uint256 toTreasury) {
        supply = BOSSES.totalSupply();
        uint256 eligible = supply < MAX_BOSSES ? supply : MAX_BOSSES;
        toBosses = (amount * BOSS_BPS * eligible) / (BPS * MAX_BOSSES);
        toMiners = (amount * MINER_BPS) / BPS;
        toTreasury = amount - toBosses - toMiners;
    }
}
