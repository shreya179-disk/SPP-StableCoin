// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

//Collateral: Exogenous (ETH & BTC)
// Minting: Algorithmic
//Relative Stability: Pegged to USD
//This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system

contract defi_StableCoin is ERC20Burnable, Ownable{
    error defi_StableCoin_MustBeMoreThanZero();
    error defi_StableCoin_BurnAmountExceedsBalance();
    error defi_StableCoin_NotZeroAddress();

    constructor()ERC20("DecentralizedStableCoin", "SPP"){}

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0){
            revert defi_StableCoin_MustBeMoreThanZero();
        }
        if (balance < _amount){
            revert defi_StableCoin_BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    
    }
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert defi_StableCoin_NotZeroAddress();
        }
        if (_amount <= 0) {
            revert defi_StableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }

}