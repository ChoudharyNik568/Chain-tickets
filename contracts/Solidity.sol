// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TicketChain is ERC721, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    
    // Ticket struct
    struct Ticket {
        uint256 eventId;
        uint256 originalPrice;
        uint256 currentPrice;
        uint256 maxResalePrice;
        bool isUsed;
        uint256 seatNumber; // 0 for general admission
    }
    
    // Event struct
    struct Event {
        address organizer;
        string name;
        string description;
        uint256 date; // Unix timestamp
        string location;
        uint256 totalTickets;
        uint256 ticketsSold;
        uint256 ticketPrice;
        uint256 royaltyPercent; // Out of 10000 (for decimal precision)
        uint256 maxResaleMultiplier; // Multiplied by 100 (e.g., 150 = 1.5x)
        bool isActive;
    }
    
    // Mappings
    mapping(uint256 => Ticket) private _tickets;
    mapping(uint256 => Event) private _events;
    mapping(uint256 => address) private _originalOwners;
    
    // Events
    event EventCreated(uint256 eventId, address organizer);
    event TicketPurchased(uint256 ticketId, uint256 eventId, address buyer);
    event TicketResold(uint256 ticketId, uint256 newPrice, address seller);
    event TicketTransferred(uint256 ticketId, address from, address to, uint256 price);
    event TicketValidated(uint256 ticketId, address validator);
    
    constructor() ERC721("TicketChain", "TICKET") {}
    
    // Create a new event (only owner for simplicity, could be permissioned differently)
    function createEvent(
        string memory name,
        string memory description,
        uint256 date,
        string memory location,
        uint256 totalTickets,
        uint256 ticketPrice,
        uint256 royaltyPercent,
        uint256 maxResaleMultiplier
    ) external onlyOwner {
        require(date > block.timestamp, "Event date must be in the future");
        require(totalTickets > 0, "Must have at least one ticket");
        require(ticketPrice > 0, "Ticket price must be positive");
        require(royaltyPercent <= 10000, "Royalty cannot exceed 100%");
        require(maxResaleMultiplier >= 100, "Resale multiplier must be at least 1.0x");
        
        uint256 eventId = _tokenIds.current();
        _tokenIds.increment();
        
        _events[eventId] = Event({
            organizer: msg.sender,
            name: name,
            description: description,
            date: date,
            location: location,
            totalTickets: totalTickets,
            ticketsSold: 0,
            ticketPrice: ticketPrice,
            royaltyPercent: royaltyPercent,
            maxResaleMultiplier: maxResaleMultiplier,
            isActive: true
        });
        
        emit EventCreated(eventId, msg.sender);
    }
    
    // Purchase a ticket (payable function)
    function purchaseTicket(uint256 eventId, uint256 seatNumber) external payable nonReentrant {
        Event storage eventInfo = _events[eventId];
        require(eventInfo.isActive, "Event is not active");
        require(eventInfo.ticketsSold < eventInfo.totalTickets, "Event is sold out");
        require(msg.value >= eventInfo.ticketPrice, "Insufficient payment");
        
        // Check seat availability if assigned seating
        if (seatNumber > 0) {
            // This would require additional storage/mapping to track seat availability
            // For simplicity, we'll assume seat checking is handled off-chain
        }
        
        uint256 ticketId = _tokenIds.current();
        _tokenIds.increment();
        
        uint256 maxResalePrice = (eventInfo.ticketPrice * eventInfo.maxResaleMultiplier) / 100;
        
        _tickets[ticketId] = Ticket({
            eventId: eventId,
            originalPrice: eventInfo.ticketPrice,
            currentPrice: eventInfo.ticketPrice,
            maxResalePrice: maxResalePrice,
            isUsed: false,
            seatNumber: seatNumber
        });
        
        _originalOwners[ticketId] = msg.sender;
        _mint(msg.sender, ticketId);
        
        eventInfo.ticketsSold++;
        
        // Transfer payment to organizer (minus any platform fee)
        (bool sent, ) = eventInfo.organizer.call{value: msg.value}("");
        require(sent, "Failed to send Ether");
        
        emit TicketPurchased(ticketId, eventId, msg.sender);
    }
    
    // Resell a ticket (owner can set new price)
    function resellTicket(uint256 ticketId, uint256 newPrice) external {
        require(_exists(ticketId), "Ticket does not exist");
        require(ownerOf(ticketId) == msg.sender, "Not ticket owner");
        require(!_tickets[ticketId].isUsed, "Ticket already used");
        require(newPrice <= _tickets[ticketId].maxResalePrice, "Price exceeds maximum");
        
        _tickets[ticketId].currentPrice = newPrice;
        
        emit TicketResold(ticketId, newPrice, msg.sender);
    }
    
    // Purchase a resold ticket
    function purchaseResoldTicket(uint256 ticketId) external payable nonReentrant {
        require(_exists(ticketId), "Ticket does not exist");
        require(ownerOf(ticketId) != msg.sender, "Cannot buy your own ticket");
        require(!_tickets[ticketId].isUsed, "Ticket already used");
        require(msg.value >= _tickets[ticketId].currentPrice, "Insufficient payment");
        
        address seller = ownerOf(ticketId);
        address originalOwner = _originalOwners[ticketId];
        Event storage eventInfo = _events[_tickets[ticketId].eventId];
        
        // Calculate royalty
        uint256 royaltyAmount = (msg.value * eventInfo.royaltyPercent) / 10000;
        uint256 sellerAmount = msg.value - royaltyAmount;
        
        // Transfer ownership
        _transfer(seller, msg.sender, ticketId);
        
        // Distribute funds
        if (royaltyAmount > 0) {
            (bool royaltySent, ) = eventInfo.organizer.call{value: royaltyAmount}("");
            require(royaltySent, "Failed to send royalty");
        }
        
        (bool sellerSent, ) = seller.call{value: sellerAmount}("");
        require(sellerSent, "Failed to send seller payment");
        
        emit TicketTransferred(ticketId, seller, msg.sender, msg.value);
    }
    
    // Validate a ticket (only event organizer)
    function validateTicket(uint256 ticketId) external {
        require(_exists(ticketId), "Ticket does not exist");
        require(!_tickets[ticketId].isUsed, "Ticket already used");
        
        Event storage eventInfo = _events[_tickets[ticketId].eventId];
        require(msg.sender == eventInfo.organizer, "Only organizer can validate");
        
        _tickets[ticketId].isUsed = true;
        
        emit TicketValidated(ticketId, msg.sender);
    }
    
    // View functions
    function getTicketInfo(uint256 ticketId) external view returns (Ticket memory) {
        require(_exists(ticketId), "Ticket does not exist");
        return _tickets[ticketId];
    }
    
    function getEventInfo(uint256 eventId) external view returns (Event memory) {
        require(_events[eventId].organizer != address(0), "Event does not exist");
        return _events[eventId];
    }
    
    // Override transfer functions to prevent used tickets from being transferred
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        require(!_tickets[tokenId].isUsed, "Ticket has been used");
        super._beforeTokenTransfer(from, to, tokenId);
    }
}