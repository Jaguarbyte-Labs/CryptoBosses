// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IDistributor} from "./IDistributor.sol";

/**
 * @title CryptoMiners 
 * @notice Unlimited-supply collection, sister of the CryptoBosses: 1 Miner = 1 game account. ETH only.
 *
 * What the owner CAN do: change the baseURI, transfer or renounce ownership.
 * What the owner CANNOT do: pause the sale (open from deployment, forever), change the price (fixed forever at deployment), mint for free (there is no reserve), withdraw rewards,
 * change the distributor or change the revenue split (which lives in the RevenueSplitter).
 *
 * The ETH of each mint is forwarded in the same transaction to the TREASURY (set at deployment).
 * It is NOT distributed: the distributor only receives external revenue, through the RevenueSplitter.
 * This keeps the accrued value from depending on new buyers arriving.
 */
// The owner exists on purpose (baseURI) and what it CANNOT do is listed above;
// recommended: Safe multisig.
// aderyn-ignore-next-line(centralization-risk)
contract CryptoMiners is ERC721, Ownable, ReentrancyGuard {
    uint256 public constant MAX_PER_TX = 50;

    MinerDistributor public immutable DISTRIBUTOR;
    address payable public immutable TREASURY;

    uint256 public immutable price; // fixed forever (decision of 2026-11-15)
    uint256 public totalSupply;
    string private _base;

    // ---- CryptoMiner artwork: SVG pieces chosen by 7 traits taken from keccak256(tokenId) (see _traits). The colours are 6-hex strings.
    bytes private constant SVG_HEAD =
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'>";
    bytes private constant BODY_A =
        "<g fill='#";
    bytes private constant BODY_B =
        "'><path d='M62 400v-44q0-66 138-66t138 66v44z'/></g><path d='M268 292q58 18 70 64v44h-66z' fill='#000' o"
        "pacity='.2'/><path d='M146 300l16 100M254 300l-16 100M80 366H320' stroke='#f4ff52' stroke-width='9' opac"
        "ity='.95'/><path d='M146 300l16 100M254 300l-16 100M80 366H320' stroke='#fff' stroke-width='2.5' opacity"
        "='.5'/>";
    bytes private constant HEAD_A =
        "<g fill='#";
    bytes private constant HEAD_B =
        "'><rect x='180' y='268' width='40' height='36'/><circle cx='148' cy='232' r='10'/><circle cx='252' cy='2"
        "32' r='10'/><circle cx='200' cy='226' r='54'/></g><path d='M180 290q20 14 40 0v14h-40z' fill='#000' opac"
        "ity='.16'/>";
    bytes private constant HELM_A =
        "<g fill='#";
    bytes private constant HELM_B =
        "'><path d='M136 222q0-82 64-82t64 82z'/><rect x='122' y='216' width='156' height='16' rx='8'/></g><rect "
        "x='122' y='224' width='156' height='8' rx='4' fill='#000' opacity='.18'/><rect x='192' y='146' width='16"
        "' height='72' fill='#fff' opacity='.28'/><circle cx='200' cy='168' r='13' fill='#fffbe0' stroke='#3a3a44"
        "' stroke-width='3'/><circle cx='200' cy='168' r='26' fill='#fff7a8' opacity='.3'/>";
    bytes private constant GEM_A =
        "<path d='M200 188l15 15-15 20-15-20z' fill='#";
    bytes private constant GEM_B =
        "' stroke='#fff' stroke-width='2.5' stroke-opacity='.7'/><path d='M200 188l-6 15 6 20' fill='none' stroke"
        "='#fff' stroke-width='2' opacity='.45'/>";
    bytes private constant TITLE_A =
        "<text x='24' y='50' font-family='Arial,Helvetica,sans-serif' font-weight='900' font-size='27' fill='#fff"
        "' stroke='#000a' stroke-width='6' paint-order='stroke' letter-spacing='1'>CRYPTO<tspan fill='#7ef0ff'>MI"
        "NER</tspan></text><text x='24' y='92' font-family='Arial,Helvetica,sans-serif' font-weight='900' font-si"
        "ze='34' fill='#ffd36e' stroke='#000a' stroke-width='6' paint-order='stroke'>#";
    bytes private constant TITLE_B =
        "</text></svg>";
    uint256 private constant HEX_LEN = 6;
    // The 7 traits are packed one byte each in a uint256 (see _traits); trait i uses byte i of the hash.
    uint256 private constant TRAIT_BITS = 8;
    uint256 private constant TRAIT_MASK = 0xff;
    uint256 private constant T_BG = 0;
    uint256 private constant T_SKIN = 1;
    uint256 private constant T_HELM = 2;
    uint256 private constant T_VEST = 3;
    uint256 private constant T_FACE = 4;
    uint256 private constant T_TOOL = 5;
    uint256 private constant T_GEM = 6;
    uint256 private constant VEST_COUNT = 8; // 8 vest colours, equally likely
    bytes private constant VEST_HEX = "ff6b352f7fffe639468338ec06a77dff006e00b4d8a3d900"; // Orange, Blue, Red, Purple, Green, Pink, Teal, Lime
    bytes private constant SKIN_HEX = "f6d1a8e8b07ac98a559a60346b4125b8c6d6"; // Light, Medium, Tan, Brown, Dark, Robot
    bytes private constant HELM_HEX = "ffc400f1f5f9ff8a002f80ede031312b323b"; // Yellow, White, Orange, Blue, Red, Black
    bytes private constant GEM_HEX = "2be58a4aa8ffff3b5ce6fbff"; // Emerald, Sapphire, Ruby, Diamond
    // Rarity: cumulative limits out of 256 (a trait takes the first bucket whose limit is above the hash byte; the last bucket takes the rest).
    bytes private constant THR_BG = hex"4d8dbbdff6"; // Sunset 30%, Night 25%, Neon 18%, Datacenter 14%, Aurora 9%, Gold Rush 4%
    bytes private constant THR_SKIN = hex"4885b8dff8"; // Light 28%, Medium 24%, Tan 20%, Brown 15%, Dark 10%, Robot 3%
    bytes private constant THR_HELM = hex"5a92c0dff3"; // Yellow 35%, White 22%, Orange 18%, Blue 12%, Red 8%, Black 5%
    bytes private constant THR_FACE = hex"5a9ada"; // Smile 35%, Grin 25%, Shades 25%, Focused 15%
    bytes private constant THR_TOOL = hex"66a6da"; // Pickaxe 40%, GPU 25%, ASIC 20%, Gold Coin 15%
    bytes private constant THR_GEM = hex"8dcdf3"; // Emerald 55%, Sapphire 25%, Ruby 15%, Diamond 5%
    string private constant DESCRIPTION =
        "One CryptoMiner is one account in the CryptoBosses game, where players build power plants, mining halls and AI datacenters on the islands of the CryptoBosses archipelago.";

    event BaseURIChanged(string newBaseURI);

    error InvalidQuantity();
    error WrongPayment();

    /// @param treasury      Where the mint ETH goes (recommended: a multisig).
    /// @param initialPrice  Price per Miner in wei (0.001 ether); fixed forever.
    constructor(address payable treasury, uint256 initialPrice)
        ERC721("Crypto Miners", "MINER")
        Ownable(msg.sender)
    {
        require(treasury != address(0), "zero address");
        TREASURY = treasury;
        price = initialPrice;
        // The distributor is born bound to this collection and cannot be replaced.
        DISTRIBUTOR = new MinerDistributor();
    }

    function mint(uint256 quantity) external payable nonReentrant {
        if (quantity == 0 || quantity > MAX_PER_TX) revert InvalidQuantity();
        if (msg.value != price * quantity) revert WrongPayment();

        uint256 first = totalSupply;
        totalSupply = first + quantity;
        // Registers the whole batch before minting: the tokens are born without rights to what was already deposited,
        // even if the buyer is a contract that reacts in onERC721Received.
        DISTRIBUTOR.registerMints(quantity);
        // Up to MAX_PER_TX (50) mints; _safeMint reverts if a contract buyer rejects the NFT (on purpose).
        // aderyn-ignore-next-line(costly-loop, require-revert-in-loop)
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(msg.sender, first + i);
        }

        Address.sendValue(TREASURY, msg.value);
    }

    // ---------------- owner ----------------

    // Documented owner (see the top of the contract).
    // aderyn-ignore-next-line(centralization-risk)
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _base = newBaseURI;
        emit BaseURIChanged(newBaseURI);
    }

    // ---------------- metadata ----------------

    /// @notice With a baseURI set: baseURI + id (standard). Without a baseURI (as deployed), the contract itself
    ///         builds the JSON and the SVG artwork: no server, IPFS or website needs to be online for the
    ///         Miner to show in wallets and marketplaces. Seven traits (background, skin, helmet, vest, face, tool, gem)
    ///         come from keccak256(tokenId), with the rarities listed at the constants above.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Reverts if the token does not exist; the returned owner is not used here.
        // aderyn-ignore-next-line(unchecked-return)
        _requireOwned(tokenId);
        string memory id = Strings.toString(tokenId);
        if (bytes(_base).length != 0) return string.concat(_base, id);
        uint256 t = _traits(tokenId);
        bytes memory json = bytes.concat(
            '{"name":"CryptoMiner #', bytes(id), '","description":"', bytes(DESCRIPTION),
            '","image":"data:image/svg+xml;base64,', bytes(Base64.encode(_image(t, bytes(id)))),
            '","attributes":', _attributes(t), '}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// The 7 traits, one byte each: background, skin, helmet, vest, face, tool, gem
    function _traits(uint256 tokenId) private pure returns (uint256 t) {
        bytes32 h = keccak256(abi.encode(tokenId));
        t = _put(t, T_BG, _pick(uint8(h[T_BG]), THR_BG));
        t = _put(t, T_SKIN, _pick(uint8(h[T_SKIN]), THR_SKIN));
        t = _put(t, T_HELM, _pick(uint8(h[T_HELM]), THR_HELM));
        t = _put(t, T_VEST, uint8(h[T_VEST]) % VEST_COUNT);
        t = _put(t, T_FACE, _pick(uint8(h[T_FACE]), THR_FACE));
        t = _put(t, T_TOOL, _pick(uint8(h[T_TOOL]), THR_TOOL));
        t = _put(t, T_GEM, _pick(uint8(h[T_GEM]), THR_GEM));
    }

    function _put(uint256 t, uint256 trait, uint256 value) private pure returns (uint256) {
        return t | (value << (trait * TRAIT_BITS));
    }

    function _get(uint256 t, uint256 trait) private pure returns (uint256) {
        return (t >> (trait * TRAIT_BITS)) & TRAIT_MASK;
    }

    function _pick(uint8 r, bytes memory limits) private pure returns (uint256 i) {
        while (i < limits.length && r >= uint8(limits[i])) ++i;
    }

    function _hex(bytes memory palette, uint256 k) private pure returns (bytes memory c) {
        c = new bytes(HEX_LEN);
        for (uint256 i = 0; i < HEX_LEN; ++i) {
            c[i] = palette[k * HEX_LEN + i];
        }
    }

    function _image(uint256 t, bytes memory id) private pure returns (bytes memory) {
        bytes memory a = bytes.concat(SVG_HEAD, _bg(_get(t, T_BG)), BODY_A, _hex(VEST_HEX, _get(t, T_VEST)), BODY_B, _tool(_get(t, T_TOOL)));
        bytes memory b = bytes.concat(HEAD_A, _hex(SKIN_HEX, _get(t, T_SKIN)), HEAD_B, _face(_get(t, T_FACE)), HELM_A, _hex(HELM_HEX, _get(t, T_HELM)), HELM_B);
        return bytes.concat(a, b, GEM_A, _hex(GEM_HEX, _get(t, T_GEM)), GEM_B, TITLE_A, id, TITLE_B);
    }

    function _attr(string memory name, string memory value) private pure returns (bytes memory) {
        return bytes.concat('{"trait_type":"', bytes(name), '","value":"', bytes(value), '"}');
    }

    function _attributes(uint256 t) private pure returns (bytes memory) {
        bytes memory a = bytes.concat(
            "[", _attr("Background", _bgName(_get(t, T_BG))), ",", _attr("Skin", _skinName(_get(t, T_SKIN))), ",", _attr("Helmet", _helmName(_get(t, T_HELM)))
        );
        bytes memory b = bytes.concat(
            ",", _attr("Vest", _vestName(_get(t, T_VEST))), ",", _attr("Face", _faceName(_get(t, T_FACE))), ",", _attr("Tool", _toolName(_get(t, T_TOOL)))
        );
        return bytes.concat(a, b, ",", _attr("Gem", _gemName(_get(t, T_GEM))), "]");
    }

    function _bgName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[6] memory n = ["Sunset", "Night", "Neon", "Datacenter", "Aurora", "Gold Rush"];
        return n[k];
    }
    function _skinName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[6] memory n = ["Light", "Medium", "Tan", "Brown", "Dark", "Robot"];
        return n[k];
    }
    function _helmName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[6] memory n = ["Yellow", "White", "Orange", "Blue", "Red", "Black"];
        return n[k];
    }
    function _vestName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[8] memory n = ["Orange", "Blue", "Red", "Purple", "Green", "Pink", "Teal", "Lime"];
        return n[k];
    }
    function _faceName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[4] memory n = ["Smile", "Grin", "Shades", "Focused"];
        return n[k];
    }
    function _toolName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[4] memory n = ["Pickaxe", "GPU", "ASIC", "Gold Coin"];
        return n[k];
    }
    function _gemName(uint256 k) private pure returns (string memory) {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        string[4] memory n = ["Emerald", "Sapphire", "Ruby", "Diamond"];
        return n[k];
    }

    function _bg(uint256 k) private pure returns (bytes memory) {
        if (k == 0) {
            return
                "<defs><linearGradient id='a' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#1b0b3d'/><stop of"
                "fset='.5' stop-color='#b5309a'/><stop offset='.8' stop-color='#ff7a59'/><stop offset='1' stop-color='#ff"
                "c36b'/></linearGradient><linearGradient id='b' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='"
                "#13a4c4'/><stop offset='1' stop-color='#052a46'/></linearGradient></defs><rect width='400' height='400' "
                "fill='url(#a)'/><g fill='#fff' opacity='.7'><circle cx='40' cy='110' r='1.6'/><circle cx='330' cy='60' r"
                "='1.4'/><circle cx='372' cy='140' r='1.2'/><circle cx='250' cy='38' r='1.2'/></g><circle cx='200' cy='26"
                "2' r='122' fill='#ffd36e' opacity='.92'/><rect y='318' width='400' height='82' fill='url(#b)'/><path d='"
                "M0 336q25-8 50 0t50 0t50 0t50 0t50 0t50 0t50 0t50 0' stroke='#7ef0ff' stroke-width='3' fill='none' opaci"
                "ty='.4'/><path d='M62 340c2-34-4-58-14-76' stroke='#4a2f18' stroke-width='7' fill='none'/><path d='M48 2"
                "64q26-10 44 6M48 264q16-26 40-18M48 264q-6-26-30-30M48 264q-24-8-38 12M48 264q6 12 4 26' stroke='#155c32"
                "' stroke-width='8' fill='none' stroke-linecap='round'/>";
        }
        if (k == 1) {
            return
                "<defs><linearGradient id='a' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#050a24'/><stop of"
                "fset='.6' stop-color='#1a2a6b'/><stop offset='1' stop-color='#3b4fa8'/></linearGradient></defs><rect wid"
                "th='400' height='400' fill='url(#a)'/><g fill='#fff' opacity='.85'><circle cx='36' cy='70' r='1.8'/><cir"
                "cle cx='96' cy='34' r='1.4'/><circle cx='150' cy='88' r='1.2'/><circle cx='64' cy='150' r='1.5'/><circle"
                " cx='250' cy='48' r='1.6'/><circle cx='350' cy='190' r='1.3'/><circle cx='372' cy='84' r='1.8'/><circle "
                "cx='30' cy='230' r='1.2'/><circle cx='300' cy='30' r='1.2'/></g><circle cx='296' cy='112' r='58' fill='#"
                "f4f1de'/><g fill='#d9d4b8'><circle cx='278' cy='98' r='11'/><circle cx='314' cy='130' r='8'/><circle cx="
                "'300' cy='84' r='5'/></g><rect y='330' width='400' height='70' fill='#0a1240'/><path d='M0 346q25-8 50 0"
                "t50 0t50 0t50 0t50 0t50 0t50 0t50 0' stroke='#8fa8ff' stroke-width='3' fill='none' opacity='.35'/>";
        }
        if (k == 2) {
            return
                "<defs><linearGradient id='a' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#12002e'/><stop of"
                "fset='.7' stop-color='#5a0d8f'/><stop offset='1' stop-color='#ff2e93'/></linearGradient><linearGradient "
                "id='b' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#ffe66d'/><stop offset='1' stop-color='#"
                "ff2e93'/></linearGradient></defs><rect width='400' height='400' fill='url(#a)'/><circle cx='200' cy='248"
                "' r='112' fill='url(#b)'/><g fill='#5a0d8f'><rect y='262' width='400' height='4'/><rect y='282' width='4"
                "00' height='6'/><rect y='304' width='400' height='8'/></g><rect y='322' width='400' height='78' fill='#1"
                "2002e'/><path d='M0 322H400M0 340H400M0 366H400M200 322L200 400M150 322L40 400M100 322L-80 400M250 322L3"
                "60 400M300 322L480 400M50 322L-200 400M350 322L600 400' stroke='#ff6bd6' stroke-width='2' fill='none' op"
                "acity='.8'/>";
        }
        if (k == 3) {
            return
                "<defs><linearGradient id='a' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#04121a'/><stop of"
                "fset='1' stop-color='#0e3a4c'/></linearGradient><pattern id='p' width='14' height='12' patternUnits='use"
                "rSpaceOnUse'><rect x='3' y='4' width='5' height='3' fill='#2dffb2'/><rect x='9' y='4' width='3' height='"
                "3' fill='#2dc4ff'/></pattern></defs><rect width='400' height='400' fill='url(#a)'/><g fill='#0a2230' str"
                "oke='#1d6a85' stroke-width='2'><rect x='14' y='70' width='82' height='330'/><rect x='108' y='110' width="
                "'70' height='290'/><rect x='224' y='110' width='70' height='290'/><rect x='306' y='70' width='82' height"
                "='330'/></g><g fill='url(#p)'><rect x='14' y='70' width='82' height='330'/><rect x='108' y='110' width='"
                "70' height='290'/><rect x='224' y='110' width='70' height='290'/><rect x='306' y='70' width='82' height="
                "'330'/></g><rect y='356' width='400' height='44' fill='#2dc4ff' opacity='.18'/>";
        }
        // aderyn-ignore-next-line(literal-instead-of-constant)
        if (k == 4) {
            return
                "<defs><linearGradient id='a' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#020617'/><stop of"
                "fset='1' stop-color='#0b2a4d'/></linearGradient><linearGradient id='b' x1='0' y1='0' x2='0' y2='1'><stop"
                " offset='0' stop-color='#37ffb0' stop-opacity='0'/><stop offset='.5' stop-color='#37ffb0' stop-opacity='"
                ".75'/><stop offset='1' stop-color='#7a5cff' stop-opacity='0'/></linearGradient></defs><rect width='400' "
                "height='400' fill='url(#a)'/><g fill='#fff' opacity='.8'><circle cx='40' cy='60' r='1.6'/><circle cx='12"
                "0' cy='30' r='1.3'/><circle cx='330' cy='50' r='1.7'/><circle cx='370' cy='150' r='1.2'/><circle cx='60'"
                " cy='170' r='1.2'/></g><path d='M-20 120C60 40 140 190 220 90S360 30 420 100V250C340 160 260 300 180 200"
                "S60 130-20 250Z' fill='url(#b)'/><path d='M-20 200C80 110 140 260 240 160S360 110 420 190V300C340 230 26"
                "0 340 160 260S40 230-20 320Z' fill='url(#b)' opacity='.55'/><rect y='340' width='400' height='60' fill='"
                "#06182d'/>";
        }
        return
            "<defs><radialGradient id='a' cx='.5' cy='.58' r='.75'><stop offset='0' stop-color='#fff3a8'/><stop offse"
            "t='.55' stop-color='#ffc928'/><stop offset='1' stop-color='#b8730a'/></radialGradient></defs><rect width"
            "='400' height='400' fill='url(#a)'/><g fill='#fff' opacity='.2'><path d='M200 250L-40 120V40ZM200 250L11"
            "0 -40H190ZM200 250L260 -40H340ZM200 250L440 40V120ZM200 250L440 200V280ZM200 250L-40 200V280Z'/></g><g f"
            "ill='#fff' opacity='.9'><circle cx='50' cy='60' r='3'/><circle cx='350' cy='90' r='2.4'/><circle cx='84'"
            " cy='190' r='2'/><circle cx='330' cy='200' r='2.6'/></g><rect y='350' width='400' height='50' fill='#8a5"
            "206' opacity='.55'/>";
    }

    function _tool(uint256 k) private pure returns (bytes memory) {
        if (k == 0) {
            return
                "<path d='M250 400l78-150' stroke='#8a5a2c' stroke-width='11' stroke-linecap='round'/><path d='M250 400l7"
                "8-150' stroke='#5d3a18' stroke-width='3' opacity='.5'/><path d='M276 232q42 0 70 40' stroke='#cfd8e3' st"
                "roke-width='13' fill='none' stroke-linecap='round'/><path d='M276 232q42 0 70 40' stroke='#fff' stroke-w"
                "idth='4' fill='none' stroke-linecap='round' opacity='.5'/>";
        }
        if (k == 1) {
            return
                "<rect x='238' y='316' width='132' height='64' rx='7' fill='#1b2733' stroke='#37e2ff' stroke-width='2.5'/"
                "><rect x='246' y='370' width='60' height='5' fill='#e8b04a'/><g fill='#0b141c' stroke='#6fe8ff' stroke-w"
                "idth='2'><circle cx='278' cy='348' r='20'/><circle cx='332' cy='348' r='20'/></g><g stroke='#6fe8ff' str"
                "oke-width='3' stroke-linecap='round'><path d='M278 334V362M264 348H292M332 334V362M318 348H346'/></g><re"
                "ct x='238' y='322' width='132' height='4' fill='#37e2ff' opacity='.8'/>";
        }
        if (k == 2) {
            return
                "<rect x='244' y='300' width='122' height='86' rx='6' fill='#c7d0db' stroke='#5b6978' stroke-width='3'/><"
                "g fill='#8795a6'><rect x='244' y='300' width='16' height='86'/><rect x='350' y='300' width='16' height='"
                "86'/></g><circle cx='305' cy='343' r='30' fill='#17202a' stroke='#3a4756' stroke-width='3'/><g stroke='#"
                "5fd0ff' stroke-width='5' stroke-linecap='round'><path d='M305 322V364M284 343H326M290 328L320 358M320 32"
                "8L290 358'/></g><circle cx='305' cy='343' r='6' fill='#ff9f1c'/><rect x='252' y='306' width='6' height='"
                "6' fill='#2dffb2'/>";
        }
        return
            "<circle cx='318' cy='286' r='62' fill='#ffe58a' opacity='.25'/><circle cx='318' cy='286' r='44' fill='#f"
            "7b500' stroke='#b57a00' stroke-width='5'/><circle cx='318' cy='286' r='33' fill='none' stroke='#ffe58a' "
            "stroke-width='3'/><path d='M304 262h16q12 0 12 11t-12 11h-16zM304 284h18q13 0 13 12t-13 12h-18zM312 254v"
            "10M326 254v10M312 308v10M326 308v10' stroke='#8a5a00' stroke-width='6' fill='none' stroke-linejoin='roun"
            "d' stroke-linecap='round'/>";
    }

    function _face(uint256 k) private pure returns (bytes memory) {
        if (k == 0) {
            return
                "<circle cx='166' cy='250' r='7' fill='#ff6f91' opacity='.35'/><circle cx='234' cy='250' r='7' fill='#ff6"
                "f91' opacity='.35'/><circle cx='180' cy='232' r='6' fill='#14141c'/><circle cx='220' cy='232' r='6' fill"
                "='#14141c'/><circle cx='182' cy='230' r='2' fill='#fff'/><circle cx='222' cy='230' r='2' fill='#fff'/><p"
                "ath d='M180 250q20 17 40 0' stroke='#14141c' stroke-width='5' fill='none' stroke-linecap='round'/>";
        }
        if (k == 1) {
            return
                "<circle cx='166' cy='250' r='7' fill='#ff6f91' opacity='.35'/><circle cx='234' cy='250' r='7' fill='#ff6"
                "f91' opacity='.35'/><circle cx='180' cy='232' r='6' fill='#14141c'/><circle cx='220' cy='232' r='6' fill"
                "='#14141c'/><circle cx='182' cy='230' r='2' fill='#fff'/><circle cx='222' cy='230' r='2' fill='#fff'/><p"
                "ath d='M176 247q24 34 48 0z' fill='#3b0f1e'/><path d='M180 248h40q-4 8-20 8t-20-8z' fill='#fff'/><ellips"
                "e cx='200' cy='262' rx='9' ry='4' fill='#ff6b81'/>";
        }
        if (k == 2) {
            return
                "<g fill='#12121a'><rect x='156' y='222' width='40' height='24' rx='9'/><rect x='204' y='222' width='40' "
                "height='24' rx='9'/></g><path d='M196 230h8' stroke='#12121a' stroke-width='4'/><path d='M162 228l14-3M2"
                "10 228l14-3' stroke='#fff' stroke-width='3' opacity='.55' stroke-linecap='round'/><path d='M182 254q18 1"
                "0 36-2' stroke='#14141c' stroke-width='5' fill='none' stroke-linecap='round'/>";
        }
        return
            "<circle cx='166' cy='250' r='7' fill='#ff6f91' opacity='.35'/><circle cx='234' cy='250' r='7' fill='#ff6"
            "f91' opacity='.35'/><g fill='#14141c'><ellipse cx='180' cy='234' rx='6' ry='5'/><ellipse cx='220' cy='23"
            "4' rx='6' ry='5'/></g><path d='M166 220l26 6M234 220l-26 6' stroke='#14141c' stroke-width='5' stroke-lin"
            "ecap='round'/><path d='M186 256h28' stroke='#14141c' stroke-width='5' stroke-linecap='round'/>";
    }
}

/**
 * @title MinerDistributor (ETH only; formerly MiniRewardsDistributor with ETH and USDC, changed on 2026-11-15)
 * @notice Distributes ETH among the CryptoMiners existing at the moment of each deposit.
 *         Created by the CryptoMiners constructor; only it can register mints.
 *
 *  - On each deposit: accPerToken += amount / current_supply (with 18 extra digits of precision).
 *  - Each Miner, when born, stores the accumulator of that moment (debt): it only receives what comes after its mint.
 *  - No owner, no admin, no team withdrawal. Same guarantees as the BossDistributor.
 *  - Deposits made while no Miner exists stay in `pending` and are credited on the
 *    next deposit (or via flushPending) to the Miners that exist then.
 *
 * Invariant: totalClaimed <= totalDeposited, always.
 */
contract MinerDistributor is IDistributor, ReentrancyGuard {
    uint256 private constant PRECISION = 1e18;

    CryptoMiners public immutable MINERS;

    uint256 public registeredSupply;
    uint256 public accPerToken; // scaled by PRECISION
    uint256 private _carry; // scaled remainder, never lost
    uint256 public pending; // received while supply == 0
    uint256 public totalDeposited;
    uint256 public totalClaimed;
    mapping(uint256 tokenId => uint256 acc) public debt; // scaled

    event Deposited(address indexed from, uint256 amount, string ref);
    event Synced(uint256 amount);
    event MintsRegistered(uint256 firstId, uint256 quantity);
    event PendingFlushed(uint256 amount);
    event Claimed(address indexed holder, uint256 indexed tokenId, uint256 amount);

    error OnlyMiners();
    error ZeroAmount();
    error NotTokenOwner(uint256 tokenId);
    error NothingToClaim();

    constructor() {
        MINERS = CryptoMiners(msg.sender);
    }

    // ---------------- mint registration (CryptoMiners only) ----------------

    /// @notice Registers `quantity` new Miners, each starting at the current accumulator.
    function registerMints(uint256 quantity) external {
        if (msg.sender != address(MINERS)) revert OnlyMiners();
        uint256 first = registeredSupply;
        registeredSupply = first + quantity;
        uint256 acc = accPerToken;
        // One debt per new token is inherent; bounded by MAX_PER_TX (50) of CryptoMiners.
        // aderyn-ignore-next-line(costly-loop)
        if (acc != 0) for (uint256 id = first; id < first + quantity; ++id) debt[id] = acc;
        emit MintsRegistered(first, quantity);
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

    /// @notice Credits ETH that arrived without a deposit call.
    function sync() external nonReentrant returns (uint256 amount) {
        uint256 accounted = totalDeposited - totalClaimed;
        uint256 balance = address(this).balance;
        if (balance <= accounted) revert ZeroAmount();
        amount = balance - accounted;
        _credit(amount, "sync");
        emit Synced(amount);
    }

    /// @notice Distributes what stayed in `pending` (deposited before the first Miner existed).
    function flushPending() external nonReentrant {
        uint256 amount = pending;
        if (amount == 0 || registeredSupply == 0) revert ZeroAmount();
        _distribute(0);
        emit PendingFlushed(amount);
    }

    // ---------------- claims ----------------
    // Checks-effects-interactions: all accounting is written BEFORE sending ETH.

    function claim(uint256[] calldata tokenIds) external nonReentrant returns (uint256 total) {
        total = _accrueOwned(tokenIds);
        if (total == 0) revert NothingToClaim();
        // Pull payment: only what _accrueOwned checked (ownerOf(id) == msg.sender) reaches here.
        Address.sendValue(payable(msg.sender), total);
    }

    /// @notice Optional "airdrop": anyone pays the gas and each token is paid to its current owner's
    ///         address (never the caller's). Same rules as BossDistributor.claimFor.
    // ownerOf per token inside the loops is inherent (the payout goes to the CURRENT owner): one region spans claimFor ... _accrueOwned,
    // because Slither reports this file's line numbers shifted (as in the other files); regions cannot overlap.
    // slither-disable-start calls-loop
    function claimFor(uint256[] calldata tokenIds) external nonReentrant returns (uint256 paid) {
        uint256 acc = accPerToken;
        uint256 supply = registeredSupply;
        address[] memory payees = new address[](tokenIds.length);
        uint256[] memory amounts = new uint256[](tokenIds.length);
        uint256 groups = 0;
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            if (tokenIds[i] >= supply) continue;
            // ownerOf is `view` (STATICCALL) on the immutable collection: it neither changes state nor reenters.
            // aderyn-ignore-next-line(reentrancy-state-change)
            address owner = MINERS.ownerOf(tokenIds[i]);
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
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 k = 0; k < groups; ++k) Address.sendValue(payable(payees[k]), amounts[k]);
    }

    function claimable(uint256[] calldata tokenIds) external view returns (uint256 total) {
        uint256 acc = accPerToken;
        uint256 supply = registeredSupply;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            if (tokenIds[i] >= supply) continue;
            total += (acc - debt[tokenIds[i]]) / PRECISION;
        }
    }

    // ---------------- internal ----------------

    function _credit(uint256 amount, string memory ref) private {
        totalDeposited += amount;
        emit Deposited(msg.sender, amount, ref);
        if (registeredSupply == 0) pending += amount;
        else _distribute(amount);
    }

    function _distribute(uint256 amount) private {
        uint256 scaled = (amount + pending) * PRECISION + _carry;
        pending = 0;
        uint256 n = registeredSupply;
        accPerToken += scaled / n;
        _carry = scaled % n;
    }

    function _accrueOwned(uint256[] calldata tokenIds) private returns (uint256 total) {
        uint256 acc = accPerToken;
        // All or nothing: an ID not owned by the caller reverts the whole claim.
        // aderyn-ignore-next-line(costly-loop, require-revert-in-loop)
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (MINERS.ownerOf(id) != msg.sender) revert NotTokenOwner(id);
            uint256 owed = _accrue(acc, id);
            if (owed != 0) {
                total += owed;
                emit Claimed(msg.sender, id, owed);
            }
        }
        totalClaimed += total;
    }
    // slither-disable-end calls-loop

    /// @dev Advances the debt of `id` only by what is paid (the fraction below 1 wei stays with the token).
    function _accrue(uint256 acc, uint256 id) private returns (uint256 owed) {
        uint256 delta = acc - debt[id];
        owed = delta / PRECISION;
        if (owed != 0) debt[id] = acc - (delta % PRECISION);
    }
}
