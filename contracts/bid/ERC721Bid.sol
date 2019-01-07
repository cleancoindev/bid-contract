pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/Address.sol";
import "./BidStorage.sol";


contract ERC721Bid is Ownable, Pausable, BidStorage {
    using SafeMath for uint256;
    using Address for address;

    /**
    * @dev Constructor of the contract.
    */
    constructor(address _manaToken, address _owner) Ownable() Pausable() public {
        manaToken = ERC20Interface(_manaToken);
        // Set owner
        transferOwnership(_owner);
    }

    function placeBid(
        address _tokenAddress, 
        uint256 _tokenId,
        uint256 _price,
        uint256 _expiresIn
    )
        public
    {
        _placeBid(
            _tokenAddress, 
            _tokenId,
            _price,
            _expiresIn,
            ""
        );
    }

    function placeBid(
        address _tokenAddress, 
        uint256 _tokenId,
        uint256 _price,
        uint256 _expiresIn,
        bytes _fingerprint
    )
        public
    {
        _requireComposableERC721(_tokenAddress, _tokenId, _fingerprint);
        _placeBid(
            _tokenAddress, 
            _tokenId,
            _price,
            _expiresIn,
            _fingerprint 
        );
    }

    function _placeBid(
        address _tokenAddress, 
        uint256 _tokenId,
        uint256 _price,
        uint256 _expiresIn,
        bytes memory _fingerprint
    )
        private
        whenNotPaused()
    {
        _requireERC721(_tokenAddress);

        require(_price > 0, "Price should be bigger than 0");

        _requireBidderBalance(msg.sender, _price);       

        uint256 expiresAt = block.timestamp.add(_expiresIn);
        require(
            expiresAt > block.timestamp.add(MIN_BID_DURATION), 
            "The bid should be more than 1 minute in the future"
        );

        require(
            expiresAt < block.timestamp.add(MAX_BID_DURATION), 
            "The bid longs 6 months at the most"
        );

        ERC721Interface token = ERC721Interface(_tokenAddress);
        require(token.ownerOf(_tokenId) != address(0), "Token should have an owner");
        


        bytes32 bidId = keccak256(
            abi.encodePacked(
                block.timestamp,
                msg.sender,
                _tokenAddress,
                _tokenId,
                _price,
                _expiresIn,
                _fingerprint
            )
        );

        uint256 bidIndex;

        if (_bidderHasAnActiveBid(_tokenAddress, _tokenId, msg.sender)) {
            (,bidIndex) = getActiveBidIdAndIndex(_tokenAddress, _tokenId, msg.sender);
        } else {
            // Use the bid counter to assign the index if there is not an active bid. 
            bidIndex = bidCounterByToken[_tokenAddress][_tokenId];  
            // Increase bid counter 
            bidCounterByToken[_tokenAddress][_tokenId]++;
        }

        bidByTokenAndBidder[_tokenAddress][_tokenId][msg.sender] = bidId;
        bidIndexByBidId[bidId] = bidIndex;

        // Save Bid
        bidsByToken[_tokenAddress][_tokenId][bidIndex] = Bid({
            id: bidId,
            bidder: msg.sender,
            tokenAddress: _tokenAddress,
            tokenId: _tokenId,
            price: _price,
            expiresAt: expiresAt,
            fingerprint: _fingerprint
        });

        emit BidCreated(
            bidId,
            _tokenAddress,
            _tokenId,
            msg.sender,
            _price,
            expiresAt,
            _fingerprint     
        );
    }

    /**
    * @dev
    * @return uint256 - index of the bid
    */
    function getActiveBidIdAndIndex(address _tokenAddress, uint256 _tokenId, address _bidder) 
        public
        view 
        returns (bytes32, uint256)
    {
        bytes32 bidId = bidByTokenAndBidder[_tokenAddress][_tokenId][_bidder];
        uint256 bidIndex = bidIndexByBidId[bidId];
        // Bid index should be inside bounds
        if (bidIndex < bidCounterByToken[_tokenAddress][_tokenId]) {
            Bid memory bid = bidsByToken[_tokenAddress][_tokenId][bidIndex];
            if (bid.bidder == _bidder) {
                return (bid.id, bidIndex);
            }
        }
        revert("Bidder has not an active bid for this token");
    }

    function _bidderHasAnActiveBid(address _tokenAddress, uint256 _tokenId, address _bidder) 
        internal
        view 
        returns (bool)
    {
        bytes32 bidId = bidByTokenAndBidder[_tokenAddress][_tokenId][_bidder];
        uint256 bidIndex = bidIndexByBidId[bidId];
        // Bid index should be inside bounds
        if (bidIndex < bidCounterByToken[_tokenAddress][_tokenId]) {
            Bid memory bid = bidsByToken[_tokenAddress][_tokenId][bidIndex];
            return bid.bidder == _bidder;
        }
        return false;
    }

    /**
    * @notice Handle the receipt of an NFT
    * @dev The ERC721 smart contract calls this function on the recipient
    * after a `safetransfer`. This function MAY throw to revert and reject the
    * transfer. Return of other than the magic value MUST result in the
    * transaction being reverted.
    * Note: the contract address is always the message sender.
    * @param _from The address which previously owned the token
    * @param _tokenId The NFT identifier which is being transferred
    * @param _data Additional data with no specified format
    * @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    */
    function onERC721Received(
        address _from,
        address /*_to*/,
        uint256 _tokenId,
        bytes memory _data
    )
        public
        whenNotPaused()
        returns (bytes4)
    {
        bytes32 bidId = _bytesToBytes32(_data);
        uint256 bidIndex = bidIndexByBidId[bidId];

        // Sender is the token contract
        Bid memory bid = _getBid(msg.sender, _tokenId, bidIndex);

        // Check if the bid is valid.
        require(
            // solium-disable-next-line operator-whitespace
            bid.id == bidId &&
            bid.expiresAt >= block.timestamp, 
            "Invalid bid"
        );

        address bidder = bid.bidder;
        uint256 price = bid.price;
        
        // Check fingerprint if apply
        _requireComposableERC721(msg.sender, _tokenId, bid.fingerprint);

        // Calculate share amount
        uint256 saleShareAmount = 0;
        if (ownerCutPerMillion > 0) {
            // Calculate sale share
            saleShareAmount = price.mul(ownerCutPerMillion).div(ONE_MILLION);
        }
        // Check if bidder has funds
        _requireBidderBalance(bidder, price.add(saleShareAmount));

        // Delete bid references from contract storage
        delete bidIndexByBidId[bidId];
        delete bidByTokenAndBidder[msg.sender][_tokenId][bidder];

        // Reset bid counter (used to invalidate other bids placed for the token)
        delete bidCounterByToken[msg.sender][_tokenId];
        
        // Transfer token to bidder
        ERC721Interface(msg.sender).transferFrom(address(this), bidder, _tokenId);

        if (ownerCutPerMillion > 0) {
            // Transfer share amount for bid conctract Owner
            require(
                manaToken.transferFrom(bidder, owner(), saleShareAmount),
                "Transfering the cut to the bid contract owner failed"
            );
        }
        // Transfer MANA from bidder to token owner
        require(
            manaToken.transferFrom(bidder, _from, price),
            "Transfer MANA to owner failed"
        );
       
        emit BidAccepted(
            bidId,
            msg.sender,
            _tokenId,
            bidder,
            _from,
            price.add(saleShareAmount)
        );

        return ERC721_Received;
    }

    function cancelBid(address _tokenAddress, uint256 _tokenId) public whenNotPaused() {
        // Get active bid
        (bytes32 bidId, uint256 bidIndex) = getActiveBidIdAndIndex(
            _tokenAddress, 
            _tokenId,
            msg.sender
        );


        // Delete bid references
        delete bidIndexByBidId[bidId];
        delete bidByTokenAndBidder[_tokenAddress][_tokenId][msg.sender];
        
        // Use safeMath
        // Check if the bid is at the end of the mapping
        uint256 lastBidIndex = bidCounterByToken[_tokenAddress][_tokenId] - 1;
        if (lastBidIndex != bidIndex) {
            // Move last bid to the removed place
            Bid storage lastBid = bidsByToken[_tokenAddress][_tokenId][lastBidIndex];
            bidsByToken[_tokenAddress][_tokenId][bidIndex] = lastBid;
        }
        
        // Delete empty index
        delete bidsByToken[_tokenAddress][_tokenId][lastBidIndex];

        // Decrease bids counter
        bidCounterByToken[_tokenAddress][_tokenId]--;

        // emit BidCancelled event
        emit BidCancelled(
            bidId,
            _tokenAddress,
            _tokenId,
            msg.sender
        );
    }

    function getBidByToken(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        public 
        view
        returns (bytes32, address, uint256, uint256) 
    {
        
        Bid memory bid = _getBid(_tokenAddress, _tokenId, _index);
        return (
            bid.id,
            bid.bidder,
            bid.price,
            bid.expiresAt
        );
    }

    function _getBid(address _tokenAddress, uint256 _tokenId, uint256 _index) 
        internal 
        view 
        returns (Bid memory)
    {
        require(_index < bidCounterByToken[_tokenAddress][_tokenId], "Invalid index");
        return bidsByToken[_tokenAddress][_tokenId][_index];
    }

     /**
    * @dev Sets the share cut for the owner of the contract that's
    * charged to the seller on a successful sale
    * @param _ownerCutPerMillion - Share amount, from 0 to 999,999
    */
    function setOwnerCutPerMillion(uint256 _ownerCutPerMillion) external onlyOwner {
        require(_ownerCutPerMillion < ONE_MILLION, "The owner cut should be between 0 and 999,999");

        ownerCutPerMillion = _ownerCutPerMillion;
        emit ChangedOwnerCutPerMillion(ownerCutPerMillion);
    }

    function _bytesToBytes32(bytes memory _data) internal pure returns (bytes32) {
        require(_data.length == 32, "Data should be 32 bytes length");

        bytes32 bidId;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            bidId := mload(add(_data, 0x20))
        }
        return bidId;
    }

    function _requireERC721(address _tokenAddress) internal view {
        require(_tokenAddress.isContract(), "Token should be a contract");

        ERC721Interface token = ERC721Interface(_tokenAddress);
        require(
            token.supportsInterface(ERC721_Interface),
            "Token has an invalid ERC721 implementation"
        );
    }

    function _requireComposableERC721(
        address _tokenAddress,
        uint256 _tokenId,
        bytes memory _fingerprint
    )
        internal
        view
    {
        ERC721Verifiable composableToken = ERC721Verifiable(_tokenAddress);
        if (composableToken.supportsInterface(ERC721Composable_ValidateFingerprint)) {
            require(
                composableToken.verifyFingerprint(_tokenId, _fingerprint),
                "Token fingerprint is not valid"
            );
        }
    }

    function _requireBidderBalance(address _bidder, uint256 _price) internal view {
        require(
            manaToken.balanceOf(_bidder) >= _price,
            "Insufficient funds"
        );
        require(
            manaToken.allowance(_bidder, address(this)) >= _price,
            "The contract is not authorized to use MANA on bidder behalf"
        );        
    }
}
