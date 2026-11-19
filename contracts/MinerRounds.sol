// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IDistributor, ISupply} from "./IDistributor.sol";

/**
 * @title MinerRounds
 * @notice Ticket for the game rounds, in ETH (decisions of 2026-11-12 and 2026-11-13).
 *
 * Ticket: `price` per 1-hour round (0.00003 ETH at deployment), split into THREE equal parts in the same transaction:
 *   - 1/3 goes to the treasury (TREASURY, immutable);
 *   - 1/3 goes to the RevenueSplitter (51% Bosses / 4% Miners / 45% treasury);
 *   - 1/3 stays here, in the pot of each covered round.
 * The price may range from 1/10 to 10x the launch price (MIN_PRICE and MAX_PRICE, set at deployment and immutable; decision of
 * 2026-11-15) and is always a multiple of 3 wei.
 *
 * Network fee (decision of 2026-11-16): on top of the ticket, each round carries `gasFee` (0.00001 ETH at deployment), forwarded
 * in the same transaction to the SETTLER, which pays the gas of recording calls, settling rounds and recording refunds: the
 * rounds pay for their own operation. It never enters the three parts nor the pot, and nothing stays here. The owner may set
 * it between 0 and MAX_GAS_FEE (= the launch ticket price, immutable). `price()` = ticket + gasFee (what the buyer pays).
 *
 * Pass: `buy(miner, rounds)` gives the Miner entry for `rounds` CONSECUTIVE rounds (round = block.timestamp / 1 hour, the same
 * formula as the game server), starting at the current round or extending a valid pass. The pass belongs to the Miner (the NFT);
 * anyone may pay for any Miner. `passEnd(miner)` = first round without entry (the game server reads this name).
 *
 * Round prize ("BTC up or down" call + game ranking), modeled on Polymarket's 1-hour markets:
 *   1. Within the first PICK_WINDOW (31 min) of the hour, the game server (SETTLER) records `picksRoot[r]`, the digest of the
 *      list of calls (miner, direction, time of the call) from players with a pass for round r (a single ticket for the current
 *      hour is enough; decision of 2026-11-16). The game closes calls at 30:00 so the root fits in the window. The full list is
 *      published by the game; once the root is recorded it cannot be changed.
 *   2. Price reference: the 1-hour BTC-USD candle on Coinbase that opens at the start of the round. "Up" if the
 *      close is GREATER THAN OR EQUAL to the open; otherwise "down". It is public, free data (Coinbase Exchange API /candles) that anyone
 *      can check afterwards.
 *   3. After the hour, `settle(r, open, close, winners)` records both prices (in US cents) and receives, in
 *      order of the prize curve, up to 30 Miners that called it right. The contract checks that each one had a pass for that round and
 *      computes the prizes by the fixed rule below. The winners are listed from the highest
 *      weight to the lowest; the weight comes from the time of each call and public prices (early or less obvious calls weigh
 *      more), computed off-chain and cross-checked by three verifiers before the settler sends it. Each winning Miner accrues its prize here; `claim` pays the current owner.
 *
 * Prize rule (k winners, pot P): each first receives a floor = min(price, P / k); the rest is split with weights
 * k^2, (k-1)^2, ..., 1 (the 1st takes much more). No winners, no recorded calls or round not settled: the whole pot carries
 * over to the next round (it never goes to the team). Rounding remainders also carry over.
 *
 * Rounds that did not count (decision of 2026-11-14): the game splits each round into rooms of up to 100 players, and a room
 * only counts with at least 5 real Miners. A Miner with a pass that did not play in a valid room (room too small, or did not
 * join) does NOT spend the round: every hour the SETTLER records `creditRoot`, the root of a CUMULATIVE list (miner, total
 * rounds to give back), and anyone calls `refund` with the proof to extend the Miner's pass. Cap: a Miner never gets back more
 * rounds than it bought (`bought`). Refunded rounds put nothing in the pot (their third already went to the pot of the hour
 * that did not count, which carries over if nobody won): no ETH is created.
 *
 * What the SETTLER (game server key) CAN do: record the calls root before each round and settle the rounds in
 * order, reporting the candle prices and WHO is on the winners list and in what order. The calls, the ranking and the price
 * come from off-chain: the audit is public (root recorded before the round, published list, prices in the event, Coinbase candle).
 * What it CANNOT do: reward a Miner without a pass for that round, pay above the pot, change the rule or move ETH from here to
 * anywhere other than the owner of a winning Miner.
 * The owner (recommended: Safe) only replaces the SETTLER and adjusts the price and the network fee within the limits. No team withdrawal,
 * pause or upgrade.
 */
// aderyn-ignore-next-line(centralization-risk)
contract MinerRounds is Ownable2Step, ReentrancyGuard {
    uint256 public constant ROUND = 1 hours;
    uint256 public constant MAX_PER_TX = 24; // rounds per purchase (1 day; decision of 2026-11-16)
    uint256 public constant TOP = 30; // winners per round, at most
    uint256 public constant GRACE = 1 days; // after this, anyone may skip unsettled rounds
    uint256 public constant PICK_WINDOW = 31 minutes; // calls root of a round: accepted until 31 min into it (the game closes calls at 30:00)
    uint256 public constant PRICE_RANGE = 10; // the price ranges from 1/PRICE_RANGE to PRICE_RANGE x the launch price
    uint256 public constant PARTS = 3; // the ticket is split into 3 equal parts: treasury, splitter and pot

    ISupply public immutable MINERS;
    uint256 public immutable MIN_PRICE; // 1/10 of the launch price
    uint256 public immutable MAX_PRICE; // 10x the launch price
    uint256 public immutable MAX_GAS_FEE; // network fee per round, at most (= launch ticket price)
    IDistributor public immutable SPLITTER;
    address payable public immutable TREASURY;

    uint256 public third; // 1/3 of the price of 1 round (price = third * 3, between MIN_PRICE and MAX_PRICE). Storing the third avoids division on the money path
    address public settler;
    uint256 public gasFee; // network fee per round (wei), forwarded to the settler on each purchase
    uint256 public nextRound; // next round to settle (always in order)
    uint256 public potRate; // wei per round that the passes valid at `nextRound` put in the pot (updated when settling)
    uint256 public carry; // pot carried over to round `nextRound`
    uint256 public totalRounds; // rounds sold, in total
    uint256 public owed; // prizes accrued and not yet claimed

    mapping(uint256 minerId => uint256 round) public passStart; // first round of the current continuous pass
    mapping(uint256 minerId => uint256 round) public passEnd; // first round WITHOUT entry
    mapping(uint256 round => uint256 weiPerRound) public rateUp; // pot per round that starts counting at the round
    mapping(uint256 round => uint256 weiPerRound) public rateDown; // pot per round that stops counting at the round
    mapping(uint256 round => bytes32 root) public picksRoot;
    mapping(uint256 minerId => uint256 amount) public prize;
    mapping(uint256 minerId => uint256 rounds) public bought; // rounds bought per Miner, in total (cap for refunds)
    mapping(uint256 minerId => uint256 rounds) public refunded; // rounds already refunded per Miner
    bytes32 public creditRoot; // root of the cumulative list (miner, total to give back), recorded by the SETTLER
    uint256 public creditRound; // last round covered by creditRoot (only grows)

    event PassBought(uint256 indexed minerId, address indexed payer, uint256 fromRound, uint256 endRound, uint256 paid);
    event PicksCommitted(uint256 indexed round, bytes32 root);
    event RoundSettled(uint256 indexed round, uint64 openCents, uint64 closeCents, uint256 pot, uint256[] winners, uint256[] amounts, uint256 carried);
    event RoundSkipped(uint256 indexed round, uint256 pot);
    event PrizeClaimed(uint256 indexed minerId, address indexed to, uint256 amount);
    event PriceChanged(uint256 newPrice);
    event GasFeeChanged(uint256 newGasFee);
    event SettlerChanged(address indexed settler);
    event CreditsCommitted(uint256 indexed upToRound, bytes32 root);
    event PassRefunded(uint256 indexed minerId, uint256 rounds, uint256 endRound);

    error UnknownMiner(uint256 minerId);
    error InvalidQuantity();
    error WrongPayment();
    error InvalidPrice();
    error NotSettler();
    error TooLate();
    error WrongRound();
    error RoundNotOver();
    error NoPicks();
    error TooManyWinners();
    error NoPass(uint256 minerId);
    error Duplicate(uint256 minerId);
    error ZeroAddress();
    error BadProof(uint256 minerId);
    error NothingToRefund(uint256 minerId);
    error OverRefund(uint256 minerId);

    /// @param miners        CryptoMiners
    /// @param splitter      RevenueSplitter: receives 1/3 of each purchase
    /// @param treasury      treasury: receives 1/3 of each purchase
    /// @param settler_      game server key that records calls and settles rounds
    /// @param initialPrice  ticket of one round in wei (0.00003 ETH = 30000000000000); multiple of 3; limits = 1/10 and 10x of it
    /// @param initialGasFee network fee per round in wei (0.00001 ETH = 10000000000000), sent to the settler; at most initialPrice
    constructor(address miners, address splitter, address payable treasury, address settler_, uint256 initialPrice, uint256 initialGasFee)
        Ownable(msg.sender)
    {
        if (miners == address(0) || splitter == address(0) || treasury == address(0) || settler_ == address(0)) revert ZeroAddress();
        if (initialPrice == 0 || initialPrice % PARTS != 0 || initialGasFee > initialPrice) revert InvalidPrice();
        MINERS = ISupply(miners);
        SPLITTER = IDistributor(splitter);
        TREASURY = treasury;
        settler = settler_;
        third = initialPrice / PARTS;
        MIN_PRICE = initialPrice / PRICE_RANGE;
        MAX_PRICE = initialPrice * PRICE_RANGE;
        MAX_GAS_FEE = initialPrice;
        gasFee = initialGasFee;
        nextRound = block.timestamp / ROUND;
    }

    // ---------------- ticket ----------------

    /// @notice Pass of `rounds` consecutive rounds for the Miner, paying `price()` (ticket + network fee) per round.
    // timestamp: the round IS the hour of the network clock (same formula as the game server); a block's seconds of drift change nothing.
    // eth-send-unchecked-address: false positive; the destinations are TREASURY and SPLITTER (immutable, checked in the constructor)
    // and the settler (set only by the owner, never zero). arbitrary-send-eth: same reason; the amount is exactly the fee paid now.
    // slither-disable-start timestamp,arbitrary-send-eth
    // aderyn-ignore-next-line(eth-send-unchecked-address)
    function buy(uint256 minerId, uint256 rounds) external payable nonReentrant {
        // reentrancy-state-change: false positive; totalSupply() is a view of CryptoMiners (immutable) and the function is nonReentrant.
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (minerId >= MINERS.totalSupply()) revert UnknownMiner(minerId);
        if (rounds == 0 || rounds > MAX_PER_TX) revert InvalidQuantity();
        uint256 part = third * rounds;
        uint256 fee = gasFee * rounds;
        if (msg.value != part * PARTS + fee) revert WrongPayment();
        uint256 r = block.timestamp / ROUND;
        uint256 end = passEnd[minerId];
        uint256 from = end > r ? end : r;
        if (end < r) passStart[minerId] = r; // new pass; if extending (end >= r), the start stays
        uint256 newEnd = from + rounds;
        passEnd[minerId] = newEnd;
        // each purchased segment puts `third` in the pot of each round it covers (an older segment keeps the value of its time)
        rateUp[from] += third;
        rateDown[newEnd] += third;
        totalRounds += rounds;
        bought[minerId] += rounds;
        emit PassBought(minerId, msg.sender, from, newEnd, msg.value);

        Address.sendValue(TREASURY, part);
        SPLITTER.depositETH{value: part}("game rounds");
        if (fee != 0) Address.sendValue(payable(settler), fee); // network fee: the rounds pay for their own settlement gas
    }
    // slither-disable-end timestamp,arbitrary-send-eth

    // ---------------- calls and settlement (game server) ----------------
    // From here to the end of the contract: `timestamp` (1-hour rounds by the network clock; a block's seconds of drift change
    // nothing) and `costly-loop` (skip passes as many rounds as the caller chooses; one write per round is inherent). Marked as a
    // region, not line by line, because Slither (11/14) reports this file's line numbers shifted (up to 10 lines).
    // slither-disable-start timestamp,costly-loop

    modifier onlySettler() {
        if (msg.sender != settler) revert NotSettler();
        _;
    }

    /// @notice Records the root of the calls list for round `round`. Only until PICK_WINDOW (31 min) into the round, and once.
    // slither-disable-next-line timestamp
    function commitPicks(uint256 round, bytes32 root) external onlySettler {
        if (block.timestamp >= round * ROUND + PICK_WINDOW || picksRoot[round] != bytes32(0) || root == bytes32(0)) revert TooLate();
        picksRoot[round] = root;
        emit PicksCommitted(round, root);
    }

    /// @notice Settles round `round` (= nextRound).
    /// @param openCents   open of the 1-hour BTC-USD Coinbase candle that starts at the round's hour, in cents
    /// @param closeCents  close of the same candle, in cents ("up" if closeCents >= openCents)
    /// @param winners     up to 30 Miners that called the direction right, 1st to last; empty = the pot carries over
    // slither-disable-next-line timestamp
    function settle(uint256 round, uint64 openCents, uint64 closeCents, uint256[] calldata winners) external nonReentrant onlySettler {
        if (round != nextRound) revert WrongRound();
        if (block.timestamp < (round + 1) * ROUND) revert RoundNotOver();
        if (openCents == 0 || closeCents == 0) revert InvalidPrice();
        uint256 k = winners.length;
        if (k > TOP) revert TooManyWinners();
        if (k != 0 && picksRoot[round] == bytes32(0)) revert NoPicks();
        _check(round, winners);

        uint256 pot = _open(round);
        uint256[] memory amounts = new uint256[](k);
        uint256 paid = 0;
        if (k != 0) {
            uint256 ticket = third * PARTS;
            uint256 floor_ = pot / k < ticket ? pot / k : ticket;
            uint256 rest = pot - floor_ * k;
            uint256 sum = (k * (k + 1) * (2 * k + 1)) / 6; // 1^2 + 2^2 + ... + k^2
            // one credit per winner is inherent; at most 30 (TOP)
            // aderyn-ignore-next-line(costly-loop)
            for (uint256 i = 0; i < k; ++i) {
                uint256 w = k - i;
                uint256 a = floor_ + (rest * w * w) / sum;
                amounts[i] = a;
                prize[winners[i]] += a;
                paid += a;
            }
            owed += paid;
        }
        carry = pot - paid;
        nextRound = round + 1;
        emit RoundSettled(round, openCents, closeCents, pot, winners, amounts, carry);
    }

    /// Winners: each with a pass for that round, no repeats (all or nothing: an invalid list pays nobody).
    // slither-disable-next-line timestamp
    function _check(uint256 round, uint256[] calldata winners) private view {
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < winners.length; ++i) {
            uint256 w = winners[i];
            if (passStart[w] > round || passEnd[w] <= round) revert NoPass(w);
            // aderyn-ignore-next-line(require-revert-in-loop)
            for (uint256 j = 0; j < i; ++j) if (winners[j] == w) revert Duplicate(w);
        }
    }

    /// @notice Records the root of the CUMULATIVE list of rounds to give back, covering up to round `upToRound` (already over).
    ///         Leaf = keccak256(keccak256(abi.encode(minerId, total))). The full list is published by the game.
    function commitCredits(uint256 upToRound, bytes32 root) external onlySettler {
        if (block.timestamp < (upToRound + 1) * ROUND) revert RoundNotOver();
        if (root == bytes32(0) || (creditRound != 0 && upToRound <= creditRound)) revert WrongRound();
        creditRoot = root;
        creditRound = upToRound;
        emit CreditsCommitted(upToRound, root);
    }

    /// @notice Extends the Miner's pass by the rounds that did not count. Anyone may call (it only benefits the Miner).
    /// @param total  cumulative total of rounds to give back to the Miner, as in the published list
    function refund(uint256 minerId, uint256 total, bytes32[] calldata proof) external {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(minerId, total))));
        if (!MerkleProof.verifyCalldata(proof, creditRoot, leaf)) revert BadProof(minerId);
        uint256 done = refunded[minerId];
        if (total <= done) revert NothingToRefund(minerId);
        if (total > bought[minerId]) revert OverRefund(minerId);
        uint256 add = total - done;
        refunded[minerId] = total;
        uint256 r = block.timestamp / ROUND;
        uint256 end = passEnd[minerId];
        if (end < r) { passStart[minerId] = r; end = r; } // expired pass: restarts now
        passEnd[minerId] = end + add; // no rateUp/rateDown: a refunded round puts no ETH in the pot
        emit PassRefunded(minerId, add, end + add);
    }

    /// @notice Carries over (without a prize) the next `count` rounds already over. The settler may always; anyone may
    ///         once the round ended more than 1 day ago (the game stopped): the pot is never stuck.
    // slither-disable-next-line timestamp,costly-loop
    function skip(uint256 count) external nonReentrant {
        // amount chosen by the caller (may be split across calls); stops at the first round that cannot be skipped yet
        // aderyn-ignore-next-line(costly-loop, require-revert-in-loop)
        for (uint256 n = 0; n < count; ++n) {
            uint256 round = nextRound;
            uint256 end = (round + 1) * ROUND;
            if (block.timestamp < end || (msg.sender != settler && block.timestamp < end + GRACE)) revert RoundNotOver();
            uint256 pot = _open(round);
            carry = pot;
            nextRound = round + 1;
            emit RoundSkipped(round, pot);
        }
    }

    // ---------------- prizes ----------------

    /// @notice Pays the accrued prizes of the Miners to the current owner of each NFT. Anyone may call.
    /// A contract owner that rejects ETH makes the call revert: remove that Miner from the list (its prize stays stored).
    // arbitrary-send-eth: false positive; the destination is the ownerOf of the winning Miner, read at call time. calls-loop: one ownerOf per
    // Miner is inherent (the prize belongs to the current owner); the function is nonReentrant and the prize is zeroed before any call.
    // Order: first zero the listed prizes and read the owners; only then send the ETH (nothing is written after sending).
    // eth-send-unchecked-address: false positive for the same reason (destination = owner of the winning Miner).
    // slither-disable-end timestamp,costly-loop
    // slither-disable-start arbitrary-send-eth,calls-loop,costly-loop
    // aderyn-ignore-next-line(eth-send-unchecked-address)
    function claim(uint256[] calldata minerIds) external nonReentrant returns (uint256 total) {
        uint256 n = minerIds.length;
        address[] memory to = new address[](n);
        uint256[] memory amount = new uint256[](n);
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = minerIds[i];
            uint256 a = prize[id];
            if (a == 0) continue;
            prize[id] = 0;
            owed -= a;
            total += a;
            amount[i] = a;
            // reentrancy-state-change: false positive; ownerOf is a view of CryptoMiners (immutable) and the function is nonReentrant
            // aderyn-ignore-next-line(reentrancy-state-change)
            to[i] = IERC721(address(MINERS)).ownerOf(id);
            emit PrizeClaimed(id, to[i], a);
        }
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < n; ++i) if (amount[i] != 0) Address.sendValue(payable(to[i]), amount[i]);
    }
    // slither-disable-end arbitrary-send-eth,calls-loop,costly-loop
    // slither-disable-start timestamp,costly-loop

    // ---------------- owner ----------------

    /// @notice Adjusts the round price between MIN_PRICE and MAX_PRICE. Multiple of 3 wei, so the three parts are equal.
    // aderyn-ignore-next-line(centralization-risk)
    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice < MIN_PRICE || newPrice > MAX_PRICE || newPrice % PARTS != 0) revert InvalidPrice();
        third = newPrice / PARTS;
        emit PriceChanged(newPrice);
    }

    /// @notice Adjusts the network fee per round between 0 and MAX_GAS_FEE (follows the network's gas price).
    // aderyn-ignore-next-line(centralization-risk)
    function setGasFee(uint256 newGasFee) external onlyOwner {
        if (newGasFee > MAX_GAS_FEE) revert InvalidPrice();
        gasFee = newGasFee;
        emit GasFeeChanged(newGasFee);
    }

    // Documented owner (see the top): replaces the server key that settles the rounds.
    // aderyn-ignore-next-line(centralization-risk)
    function setSettler(address newSettler) external onlyOwner {
        if (newSettler == address(0)) revert ZeroAddress();
        settler = newSettler;
        emit SettlerChanged(newSettler);
    }

    // ---------------- read ----------------

    /// @notice What the buyer pays for 1 round, in wei: ticket + network fee (the game reads this value to build the purchase).
    function price() external view returns (uint256) {
        return third * PARTS + gasFee;
    }

    /// @notice Ticket of 1 round in wei (split in three: treasury, splitter, pot), without the network fee.
    function ticketPrice() external view returns (uint256) {
        return third * PARTS;
    }

    function currentRound() external view returns (uint256) {
        return block.timestamp / ROUND;
    }

    // slither-disable-next-line timestamp
    function hasPass(uint256 minerId) external view returns (bool) {
        uint256 r = block.timestamp / ROUND;
        return passStart[minerId] <= r && passEnd[minerId] > r;
    }

    /// @notice Pot of round `nextRound` (the next to be settled), including what came from earlier rounds.
    function nextPot() external view returns (uint256) {
        return potRate + rateUp[nextRound] - rateDown[nextRound] + carry;
    }

    // ---------------- internal ----------------

    /// Opens round `round`: adds what the passes put in it and returns the pot (round + what came before).
    // costly-loop: called once per round (skip passes several at once, in the amount the caller chooses)
    // slither-disable-next-line costly-loop
    function _open(uint256 round) private returns (uint256) {
        potRate = potRate + rateUp[round] - rateDown[round];
        return potRate + carry;
    }
    // slither-disable-end timestamp,costly-loop
}
