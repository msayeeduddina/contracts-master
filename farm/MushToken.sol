pragma solidity ^0.8.0;

import '@openzeppelin/contracts8/access/Ownable.sol';
import '@openzeppelin/contracts8/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts8/token/ERC20/extensions/ERC20Capped.sol';

contract MushToken is ERC20Capped, Ownable {
    constructor()
        public
        ERC20('Mush', 'MUSH')
        ERC20Capped(10000000 * (10**uint256(18)))
    {}

    function mint(address account, uint256 amount) public onlyOwner {
        _mint(account, amount);
    }
}
