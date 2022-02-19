// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

contract OptionNFT is ERC721, KeeperCompatibleInterface {
    using Counters for Counters.Counter;

    struct OptionInfo {
        address originalOwnerAddr;
        address originalContractAddr;
        uint256 originalTokenId;
        uint256 exercisePrice;
        uint256 expirationTimestamp;
    }

    Counters.Counter private _tokenIdCounter;
    mapping(uint256 => OptionInfo) private _optionsInfo;

    constructor() ERC721("OptionNFT", "ONFT") {
        // Start token id from 1
        _tokenIdCounter.increment();
    }

    function _burn(uint256 tokenId) internal override {
        super._burn(tokenId);
        delete _optionsInfo[tokenId];
    }

    // This function creates (mints) option token for original NFT `originalTokenId` (for
    // your "underlying asset" in terms of trading).
    //
    // `originalContractAddr` - address of original NFT contract where your original NFT
    // was created (minted).
    //
    // `exercisePrice` - the exercise or strike price is the price at which the underlying 
    // will be delivered should the holder of an option choose to exercise his right to buy.
    //
    // `expirationTimestamp` - the expiration date is the date on which the owner of an
    // option can make the final decision to buy. After expiration, all rights and
    // obligations under the option contract cease to exist and underlying NFT will be send
    // back to the original owner that created option token.
    //
    // Before minting it sends original token to this contract address, that's why this
    // contract needs to be approved by original NFT contract to send NFT from owner to
    // option contract.
    function safeMint(
        address originalContractAddr,
        uint256 originalTokenId,
        uint256 exercisePrice,
        uint256 expirationTimestamp
    ) public {

        // Requirements:
        // 1. Sender is owner of original token
        // 2. This contract is approved
        // 3. Expiration timestamp is greater than now

        ERC721 originalContract = ERC721(originalContractAddr);

        require(originalContract.ownerOf(originalTokenId) == msg.sender,
            "Caller must own original token.");

        require(originalContract.getApproved(originalTokenId) == address(this),
            "Owner needs to get permisions (approve function) to this contract to transfer original token to this contract address.");
        
        require(expirationTimestamp > block.timestamp,
            "Expiration date must be greater than block timestamp.");

        // Transfer original token to this contract address
        originalContract.transferFrom(msg.sender, address(this), originalTokenId);

        // Mint option token to owner
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(msg.sender, tokenId);

        // Save all input info to storage
        _optionsInfo[tokenId] = OptionInfo(msg.sender, originalContractAddr, originalTokenId,
            exercisePrice, expirationTimestamp);
    }

    // This function returns original NFT to original owner and creator of option token and
    // burns option token only when caller owns option token.
    // Caller can be a person who bought option token or original owner by himself.
    function expireByOptionOwner(uint256 optionId) public {

        // Requirements:
        // 1. Sender owns option

        require(ownerOf(optionId) == msg.sender,
            "Caller must own option token.");

        _expire(optionId);
    }

    // This function returns original NFT to original owner and creator of option token and burns option token.
    // This function can be called by contract in expiration date or explicitly by option token owner.
    function _expire(uint256 optionId) internal {

        OptionInfo storage optionInfo = _optionsInfo[optionId];

        // Transfer original token to original owner address
        ERC721 originalContract = ERC721(optionInfo.originalContractAddr);
        originalContract.transferFrom(address(this), optionInfo.originalOwnerAddr, optionInfo.originalTokenId);

        // Burn option token
        _burn(optionId);
    }

    // To exercise the option, the option owner needs to pay the exercise price (strike price);
    // This payment will be sent to the option creator.
    // After that option owner will get original NFT and option token will be burned.
    function exercise(uint256 optionId) public payable {

        // Requirements:
        // 1. Sender owns option
        // 2. Sender is not original owner (use expireByOptionOwner instead)
        // 3. Check if fund is enough

        require(ownerOf(optionId) == msg.sender,
            "Caller must own option token.");

        OptionInfo storage optionInfo = _optionsInfo[optionId];

        require(optionInfo.originalOwnerAddr != msg.sender,
            "Caller can not be original option creator, use expireByOptionOwner function instead if caller owns his original option.");

        require(msg.value == optionInfo.exercisePrice,
            "Incorrect fund sent.");

        // Transfer original token to buyer address
        ERC721 originalContract = ERC721(optionInfo.originalContractAddr);
        originalContract.transferFrom(address(this), msg.sender, optionInfo.originalTokenId);

        // Burn option token
        _burn(optionId);

        // Tranfer money to original owner
        payable(optionInfo.originalOwnerAddr).transfer(msg.value);
    }

    // Function for ChainLink Keeper oracle. Executes only off-chain. Checks if need to perform Upkeep.
    // We don't use input parameters in this case. Function returns bool as result of check and memory data for transmiting to performUpkeep.
    function checkUpkeep(bytes calldata) external view override returns (bool, bytes memory) {

        // This loop iterates every OptionInfo in mapping.
        // Option tokens are ordered numbers from 1 to `_tokenIdCounter.current()`.
        // Some optionIds are burned (notice, that `_burn` is overrided).
        for (uint256 optionId = 1; optionId < _tokenIdCounter.current(); optionId++) {
            
            // If option token is not burned (notice, that `_burn` is overrided) and time limit for
            // this option has come then return true - need to perform Upkeep for option rollback.
            if (_exists(optionId) &&
                block.timestamp >= _optionsInfo[optionId].expirationTimestamp) {
                    bytes memory performData = abi.encode(optionId);
                    return (true, performData);
            }
        }

        // There are no expired options
        return (false, bytes(""));
    }

    // Function for ChainLink Keeper oracle. Executes on-chain. Triggers when checkUpkeep returns true.
    function performUpkeep(bytes calldata performData) external override {

        uint256 optionId = abi.decode(performData, (uint256));

        // Protect from transaction initialized not by Chainlink
        require(_exists(optionId),
            "Option token doesn't exist.");
        require(_optionsInfo[optionId].expirationTimestamp <= block.timestamp,
            "Expiration date has not come.");
        
        _expire(optionId);
    }
}