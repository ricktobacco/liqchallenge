pragma solidity^0.6.2;

import "contracts/token.sol";

contract AuctionRAND 
{    
    // Events that will be emitted on changes.
    event HighestBidIncreased(uint auctionId, address bidder, uint amount);

    struct Bid {
        bytes32 blinded;
        uint deposit;
    }

    struct Auction { 
        address highestBidder;
        uint highestBid;
        uint pot;

        uint deadline;
        bool ended;
    }

    struct User {
        uint signedUp; // timestamp for when the user signed up to participate in auctions
        bool refundinRAND; // TRUE indicates that user wants refunds to be paid in RAND
        uint lastBid; // timestamp of the user's last bid
    }

    bool shutdown; // false by default, if true no new bids are allowed and users may only withdraw
    uint userCount; // maximum limit of 1000 users
    uint auctionIndex; // the auction count starting from the date of launch, incrementing every 24 hours
    
    uint whenNextAuctionEnds; // when an auction ends, this critical timestamp is updated
    uint whenNextRakeIn; // needed for rakein function

    
    uint RANDperETH; // we use a dummy constant to represent the latest price of RAND 
    TokenRAND token; // reference to the RAND ERC20 token contract itself

    // Every day, the system mints a random amount (1-100) of RAND tokens
    // that go into a pot for auction. 10% of this is the system rake
    uint rake;

    // auction -> user -> toRefund
    mapping (uint => mapping(address => uint)) pendingReturns;
    // auction -> user -> bid
    mapping (uint => mapping(address => Bid)) bids;

    mapping (uint => Auction) auctions;
    mapping (address => User) users;
    
    address public owner;
    modifier onlyOwner() { 
        require (owner == msg.sender, "Sender must be owner"); 
        _;
    }

    constructor(address payable _owner, address tokenAddress, uint price) public {
        owner = _owner;
        RANDperETH = price;
        token = TokenRAND(tokenAddress);
        whenNextRakeIn = now + 365 days;
        whenNextAuctionEnds = now + 1 days;
    }
    
    function toggleRefundIn(bool state) public {
        User memory user = users[msg.sender];
        require(
            user.refundinRAND != state,
            "given state already toggled"
        );
        user.refundinRAND = state;
        users[msg.sender] = user;
    }
    // Simple administrative functions
    function toggleShutdown(bool state) public onlyOwner {
        require(
            shutdown != state,
            "given state already toggled"
        );
        shutdown = state;
    }
    function changePrice(uint newPrice) public onlyOwner { RANDperETH = newPrice; }
    function changeOwner(address newOwner) public onlyOwner { owner = newOwner; }
    
    // Once per year, the owner draws revenue from the system, and takes a 10% cut 
    // of all the RAND winnings locked in the system at that point in time.
    function rakein() public onlyOwner {
        require(whenNextRakeIn <= now);
        token.transfer(owner, rake);
        whenNextRakeIn += 365 days;
        rake = 0;
    }

    function placeBid(uint auctionId, address bidder, uint value) internal returns (bool success) {
        Auction memory auction = auctions[auctionId];
        if (value <= auction.highestBid) {
            return false;
        }
        if (auction.highestBidder != address(0)) {
            // Refund the previously highest bidder.
            pendingReturns[auctionId][auction.highestBidder] += auction.highestBid;
        }
        auction.highestBid = value;
        auction.highestBidder = bidder;
        auctions[auctionId] = auction;
        emit HighestBidIncreased(auctionId, bidder, value);
        return true;
    }
    
    function update() internal returns (bool success) {
        if (now > whenNextAuctionEnds) {
            Auction memory auction = auctions[auctionIndex];
            auction.ended = true;
            auctions[auctionIndex] = auction;

            uint randomMintAmt = uint(blockhash(block.number - 1)) % 100 + 1;
            uint mintAmtMinusCut = randomMintAmt * 90 / 100;
            
            token.mint(randomMintAmt);
            rake += randomMintAmt - mintAmtMinusCut;
            whenNextAuctionEnds += 1 days;
            auctionIndex += 1;
            
            auctions[auctionIndex] = Auction(address(0), 0, mintAmtMinusCut, whenNextAuctionEnds, false);
        } else return false;
        return true; // the ongoing auction has been updated
    }

    // users fund their blinded bid balance with an ETH amount 
    function bid(bytes32 _blindedBid) public payable {
        require(!shutdown, "New bids not allowed in system shutdown mode");
        bool updated = update();
        User memory user = users[msg.sender];
        if (user.signedUp == 0) {
            user.signedUp = now;
            uint newCount = userCount + 1;
            require(newCount <= 1000, "System supports a maximum of 1000 users");
            userCount = newCount;
        } else if (!updated) {
            require(whenNextAuctionEnds - user.lastBid >= 86400, "Users may only bid once per day"); 
        }
        user.lastBid = now;
        users[msg.sender] = user;
        bids[auctionIndex][msg.sender] = Bid(_blindedBid, msg.value);
    }

    function reveal(uint auctionId, uint value, bytes32 secret) public {
        if (auctionId == auctionIndex) {
            require(update(), "cannot reveal for an ongoing auction");
        }
        else {
            require(auctionIndex > auctionId, "can only reveal for past auctions");
        }
        Auction memory auction = auctions[auctionId];
        // after committing their bid before an auction is over, 
        // bidders have 30 days to reveal their bids before they may withdraw their refund
        require(auction.ended && now - auction.deadline < 30 days);

        Bid storage bidToCheck = bids[auctionId][msg.sender]; 
        if (bidToCheck.blinded == keccak256(abi.encodePacked(value, secret))) { 
            uint refund = bidToCheck.deposit;
            if (refund >= value) {
                if (placeBid(auctionId, msg.sender, value))
                    refund -= value;
            } // otherwise, invalid bid, do not take it into account and just refund the deposit
            // Make it impossible for the sender to re-claim the same deposit.
            bidToCheck.blinded = bytes32(0);
            pendingReturns[auctionId][msg.sender] += refund;
        }
    }

    /* 
     * If the user won an auction, 
     * Each non-winning bid becomes refundable after 30 days from when it was made. 
     * The bid is refunded in the currency the user chose when they signed up. 
     * If they chose RAND, the system mints them an amount of RAND equal in value 
     * to their ETH bid, and burns their ETH bid.
    */
    function withdraw(uint auctionId) public {
        uint amount = pendingReturns[auctionId][msg.sender];
        Auction memory auction = auctions[auctionId];
        if (amount > 0) { 
            // It is important to set this to zero because the recipient
            // can call this function again as part of the receiving call
            // before `send` returns.
            require(shutdown || now - auction.deadline >= 30 days);
            pendingReturns[auctionId][msg.sender] = 0;
            
            User memory user = users[msg.sender];

            if (auction.highestBidder == msg.sender) {
                token.transfer(msg.sender, auction.pot);
            }
            if (!user.refundinRAND && !msg.sender.send(amount)) {
                // No need to call throw here, just reset the amount owing
                pendingReturns[auctionId][msg.sender] = amount;
            } else if (user.refundinRAND) {
                // not using safemath because we are confident on the upper bounds
                token.transfer(msg.sender, amount * RANDperETH);
                address payable burner = address(0);
                burner.transfer(amount);
            }   
        }
    }
}
