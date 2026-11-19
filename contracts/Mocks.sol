// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;
import {ERC721Enumerable, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

contract MockBosses is ERC721Enumerable {
    uint256 public fakeSupply; // != 0: totalSupply pretends to be this value (tests the 10,000 cap without minting 10,000)
    constructor() ERC721("Crypto Bosses", "BOSS") {}
    function mint(address to, uint256 n) external {
        for (uint256 i; i < n; ++i) _mint(to, super.totalSupply());
    }
    function setFakeSupply(uint256 s) external { fakeSupply = s; }
    function totalSupply() public view override returns (uint256) {
        return fakeSupply != 0 ? fakeSupply : super.totalSupply();
    }
}

/// Contract holder without receive: rejects ETH.
contract EthRejecter {}

/// Contract holder that burns all gas when receiving ETH.
contract GasBurner {
    receive() external payable { while (true) {} }
}

interface IDist { function claim(uint256[] calldata ids) external returns (uint256); }

contract Reenterer {
    IDist public d; uint256[] ids; uint256 public hits;
    constructor(address _d) { d = IDist(_d); }
    function attack(uint256[] calldata _ids) external { ids = _ids; d.claim(_ids); }
    receive() external payable { hits++; if (hits < 3) d.claim(ids); }
}

interface IMiners { function mint(uint256 n) external payable; function DISTRIBUTOR() external view returns (address); }
interface IMinerDist { function claim(uint256[] calldata ids) external returns (uint256); }

/// Contract buyer that tries to claim old deposits during its own mint.
contract GreedyMinter {
    IMiners public m; uint256 public stolen; bool public tried;
    constructor(address _m) { m = IMiners(_m); }
    function buy() external payable { m.mint{value: msg.value}(1); }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        tried = true;
        uint256[] memory ids = new uint256[](1); ids[0] = id;
        try IMinerDist(m.DISTRIBUTOR()).claim(ids) returns (uint256 a) { stolen = a; } catch {}
        return this.onERC721Received.selector;
    }
    receive() external payable {}
}

