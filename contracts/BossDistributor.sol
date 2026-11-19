// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IDistributor} from "./IDistributor.sol";

interface ICryptoBosses {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
}

/**
 * @title BossDistributor (ETH only; formerly BossRewardsDistributor with ETH and USDC, changed on 2026-11-15)
 * @notice Distributes ETH among the CryptoBosses that EXIST at the moment of each deposit.
 *         Works while the sale is open: a Boss minted later only receives later deposits.
 *
 * Guarantees (verifiable by reading this code on Etherscan):
 *  - No owner, no admin, no pause, no upgrade, no team withdrawal function.
 *  - Anyone may deposit; every deposit emits a public event with a free-text reference.
 *  - The accrued amount belongs to the NFT: whoever holds the token at claim time receives its accrual.
 *
 * How it works without a mint hook in CryptoBosses:
 *  - CryptoBosses mints sequential IDs (tokenId = totalSupply at mint time) and has no
 *    public burn. Hence token `id` existed at a deposit  <=>  id < supply of that deposit.
 *  - Each deposit adds amount/supply to the accumulator `accPerToken` and records a checkpoint
 *    (supply, accumulator). Since supply only grows, the deposits in which a token existed
 *    form a suffix of the list; a binary search finds its starting point.
 *  - Consecutive deposits with the same supply are merged into one checkpoint (at most one per supply).
 *
 * Invariant: totalClaimed <= totalDeposited, always.
 */
contract BossDistributor is IDistributor, ReentrancyGuard {
    uint256 private constant PRECISION = 1e18;

    ICryptoBosses public immutable BOSSES;

    struct Checkpoint {
        uint256 supply; // Bosses existing at this deposit
        uint256 accAfter; // accumulator (scaled) after it
    }

    Checkpoint[] private _checkpoints;
    uint256 public accPerToken; // scaled by PRECISION
    uint256 private _carry; // scaled remainder, never lost
    uint256 public pending; // received while supply == 0
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    /// @dev debt + 1 (0 = token not initialized yet).
    mapping(uint256 tokenId => uint256 debtPlus1) private _debtPlus1;

    event Deposited(address indexed from, uint256 amount, uint256 supply, string ref);
    event Synced(uint256 amount);
    event Claimed(address indexed holder, uint256 indexed tokenId, uint256 amount);

    error ZeroAmount();
    error NotTokenOwner(uint256 tokenId);
    error NothingToClaim();

    /// @param bosses CryptoBosses address (mainnet: 0x4958b779Bf6DB003DD87F67F0fc89d049d227C17).
    constructor(address bosses) {
        require(bosses != address(0), "zero address");
        BOSSES = ICryptoBosses(bosses);
    }

    // ---------------- deposits (anyone) ----------------

    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _credit(msg.value, "");
    }

    function depositETH(string calldata ref) external payable {
        if (msg.value == 0) revert ZeroAmount();
        _credit(msg.value, ref);
    }

    /// @notice Credits ETH that arrived without a deposit call (e.g. block reward, third-party selfdestruct).
    function sync() external nonReentrant returns (uint256 amount) {
        uint256 accounted = totalDeposited - totalClaimed;
        uint256 balance = address(this).balance;
        if (balance <= accounted) revert ZeroAmount();
        amount = balance - accounted;
        _credit(amount, "sync");
        emit Synced(amount);
    }

    // ---------------- claims ----------------
    // Checks-effects-interactions: all accounting (debt, totalClaimed) is written BEFORE sending ETH.

    /// @notice Claims the accrual of the caller's tokens (all or nothing: an ID owned by someone else reverts).
    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 total) {
        total = _accrueOwned(tokenIds);
        if (total == 0) revert NothingToClaim();
        // Pull payment: only what _accrueOwned checked (ownerOf(id) == msg.sender) and already debited reaches here.
        Address.sendValue(payable(msg.sender), total);
    }

    /// @notice Optional "airdrop": anyone pays the gas and each token is paid to its current owner's
    ///         address (never the caller's). Consecutive IDs of the same owner become one transfer. ETH is only
    ///         pushed to wallets without code; owners that are contracts (Safe, EIP-7702) are skipped and
    ///         claim with claim. Does not revert when there is nothing to pay.
    // Slither: annotation placed before the function (it reports this file's line numbers shifted)
    // slither-disable-start calls-loop
    function claimFor(uint256[] calldata tokenIds) external nonReentrant returns (uint256 paid) {
        uint256 acc = accPerToken;
        address[] memory payees = new address[](tokenIds.length);
        uint256[] memory amounts = new uint256[](tokenIds.length);
        uint256 groups = 0;
        // 1) accounting. One ownerOf and one debt per token is inherent; the batch is chosen by the caller.
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            // ownerOf is `view` (STATICCALL) on the immutable collection: it neither changes state nor reenters.
            // aderyn-ignore-next-line(reentrancy-state-change)
            address owner = BOSSES.ownerOf(tokenIds[i]);
            if (owner.code.length != 0) continue;
            uint256 owed = _accrue(acc, tokenIds[i]);
            if (owed != 0) {
                if (groups == 0 || payees[groups - 1] != owner) payees[groups++] = owner;
                amounts[groups - 1] += owed;
                paid += owed;
                emit Claimed(owner, tokenIds[i], owed);
            }
        }
        totalClaimed += paid;
        // 2) payments: destination = ownerOf(id) read from the collection, codeless wallets only; one failure reverts the batch.
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 k = 0; k < groups; ++k) Address.sendValue(payable(payees[k]), amounts[k]);
    }
    // slither-disable-end calls-loop

    // ---------------- read ----------------

    function claimable(uint256[] calldata tokenIds) external view returns (uint256 total) {
        uint256 acc = accPerToken;
        for (uint256 i = 0; i < tokenIds.length; ++i) total += (acc - _debt(tokenIds[i])) / PRECISION;
    }

    function checkpointCount() external view returns (uint256) {
        return _checkpoints.length;
    }

    function checkpointAt(uint256 index) external view returns (uint256 supply, uint256 accAfter) {
        Checkpoint storage c = _checkpoints[index];
        return (c.supply, c.accAfter);
    }

    // ---------------- internal ----------------

    // incorrect-equality: the supply equality in _credit is intentional (same set of tokens = merge the checkpoint);
    // it does not compare balances. Marked as a region because Slither reports this file's line numbers shifted.
    // slither-disable-start incorrect-equality
    function _credit(uint256 amount, string memory ref) private {
        totalDeposited += amount;
        uint256 supply = BOSSES.totalSupply();
        emit Deposited(msg.sender, amount, supply, ref);
        if (supply == 0) {
            pending += amount;
            return;
        }
        uint256 scaled = (amount + pending) * PRECISION + _carry;
        pending = 0;
        uint256 acc = accPerToken + scaled / supply;
        accPerToken = acc;
        _carry = scaled % supply;
        uint256 n = _checkpoints.length;
        if (n != 0 && _checkpoints[n - 1].supply == supply) _checkpoints[n - 1].accAfter = acc; // mesmos tokens: funde
        else _checkpoints.push(Checkpoint({supply: supply, accAfter: acc}));
    }
    // slither-disable-end incorrect-equality

    /// @dev Accumulator the token has already "consumed". Uninitialized: the accumulator right before the first deposit
    ///      in which the token existed.
    function _debt(uint256 tokenId) private view returns (uint256) {
        uint256 stored = _debtPlus1[tokenId];
        if (stored != 0) return stored - 1;
        return _baseline(tokenId);
    }

    function _baseline(uint256 tokenId) private view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = _checkpoints.length;
        while (lo < hi) { // first index k with supply > tokenId
            uint256 mid = (lo + hi) / 2;
            if (_checkpoints[mid].supply > tokenId) hi = mid;
            else lo = mid + 1;
        }
        if (lo >= _checkpoints.length) return accPerToken; // did not exist at any deposit
        return lo == 0 ? 0 : _checkpoints[lo - 1].accAfter;
    }

    /// @dev Accounting only (no transfer): checks the owner, advances the debt and adds to totalClaimed.
    // slither-disable-start calls-loop
    function _accrueOwned(uint256[] calldata tokenIds) private returns (uint256 total) {
        uint256 acc = accPerToken;
        // All or nothing: an ID not owned by the caller reverts the whole claim. One ownerOf per token is inherent.
        // aderyn-ignore-next-line(costly-loop, require-revert-in-loop)
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (BOSSES.ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            uint256 owed = _accrue(acc, id);
            if (owed != 0) {
                total += owed;
                emit Claimed(msg.sender, id, owed);
            } else if (_debtPlus1[id] < 1) {
                _debtPlus1[id] = _baseline(id) + 1; // initialize (later reads skip the binary search)
            }
        }
        totalClaimed += total;
    }
    // slither-disable-end calls-loop

    /// @dev Advances the debt of `id` only by what is paid (the fraction below 1 wei stays with the token).
    ///      acc - (delta % PRECISION) == debt + owed * PRECISION, without multiplying the result of the division.
    function _accrue(uint256 acc, uint256 id) private returns (uint256 owed) {
        uint256 delta = acc - _debt(id);
        owed = delta / PRECISION;
        if (owed != 0) _debtPlus1[id] = acc - (delta % PRECISION) + 1;
    }
}
