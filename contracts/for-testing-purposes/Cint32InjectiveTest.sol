import "./../Cint32Injective.sol";

contract Cint32InjectiveTest{
    using Cint32Injective for uint256;
    using Cint32Injective for uint32;
    uint8 public digits;
    constructor(){
    }

    function compress(uint256 _val) public pure returns (uint32){
        return _val.compress();
    }

    function decompress(uint32 _val) public pure returns (uint256){
        return _val.decompress();
    }
}