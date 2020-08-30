pragma solidity^0.6.2;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TokenRAND is ERC20 {
    address public auctionContract;
    constructor(address auctionAddress) ERC20("RAND", "RAND") public {
        auctionContract = auctionAddress;
    }
    function mint(uint amount) public {
        require(msg.sender == auctionContract, "only auction contract can mint RAND");
        _mint(auctionContract, amount);
    }
}