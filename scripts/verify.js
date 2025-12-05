const { run } = require("hardhat");

/**
 * Contract Verification Script
 * 
 * Verifies all Diamond facets on block explorer.
 * Update DEPLOYMENT object with addresses from deploy script output.
 */

// Latest deployment (Dec 5, 2025)
const DEPLOYMENT = {
    diamond: "0xbFa4308b2b0b3d7385Cd1fFBEF5383080B6c7916",
    facets: {
        diamondCut: "0x5785Fa95D7C35C08DE4419047108694489B0edd3",
        diamondLoupe: "0x4fe0d109A814B8a117c4074c2c74ffD2ef80fdeF",
        token: "0xd8f01298A63BcEaAb66624F0db3066420e57B26e",
        trading: "0xCd3ad3c1287f6aDdd959F6f370Ed396652Ff4f3f",
        graduation: "0x5A197a0Cd36BeE7DA98c05F40B2709c6aD7B2395",
        fee: "0x86DD9C8A84B62E8c21e48c3FbA598FA90da07607",
        security: "0x034a80a5d6Bde88c03dF7c9A786690A4Fe45Bc4D",
        admin: "0xe2C80379B99FDc8985C964C98bF52b1c59444DD3",
        erc6909: "0x196899fD510C59D2Ea615cA379eC1a22F882FB69",
        wrapper: "0x6423De9c60EF0D4BD383CbB298Fb93fC8e5b43F1"
    },
    diamondInit: "0x77057FcB69BD57e842c70408B15F8fE314bEe44b",
    owner: "0x68915D1eA12Eb987956e4e647289611e31a982F7"
};

const FACET_PATHS = {
    diamondCut: "contracts/facets/DiamondCutFacet.sol:DiamondCutFacet",
    diamondLoupe: "contracts/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet",
    token: "contracts/facets/TokenFacet.sol:TokenFacet",
    trading: "contracts/facets/TradingFacet.sol:TradingFacet",
    graduation: "contracts/facets/GraduationFacet.sol:GraduationFacet",
    fee: "contracts/facets/FeeFacet.sol:FeeFacet",
    security: "contracts/facets/SecurityFacet.sol:SecurityFacet",
    admin: "contracts/facets/AdminFacet.sol:AdminFacet",
    erc6909: "contracts/facets/ERC6909Facet.sol:ERC6909Facet",
    wrapper: "contracts/facets/WrapperFacet.sol:WrapperFacet"
};

const DIAMOND_PATH = "contracts/Diamond.sol:Diamond";
const INIT_PATH = "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit";

async function verify(address, contractPath, constructorArgs = []) {
    console.log(`Verifying ${contractPath}...`);
    try {
        await run("verify:verify", {
            address,
            constructorArguments: constructorArgs,
            contract: contractPath
        });
        console.log(`✓ Verified`);
        return true;
    } catch (e) {
        if (e.message.includes("Already Verified")) {
            console.log(`✓ Already verified`);
            return true;
        }
        console.log(`✗ Failed: ${e.message}`);
        return false;
    }
}

async function main() {
    console.log("Diamond Contract Verification\n");

    if (!DEPLOYMENT.diamond) {
        console.error("Error: Update DEPLOYMENT object with addresses from deploy output");
        process.exit(1);
    }

    let passed = 0;
    let total = 0;

    // Verify Diamond
    total++;
    if (await verify(
        DEPLOYMENT.diamond,
        DIAMOND_PATH,
        [DEPLOYMENT.owner, DEPLOYMENT.facets.diamondCut]
    )) passed++;

    // Verify all facets
    for (const [name, address] of Object.entries(DEPLOYMENT.facets)) {
        if (!address) continue;
        total++;
        if (await verify(address, FACET_PATHS[name])) passed++;
    }

    // Verify DiamondInit
    if (DEPLOYMENT.diamondInit) {
        total++;
        if (await verify(DEPLOYMENT.diamondInit, INIT_PATH)) passed++;
    }

    console.log(`\nVerification Complete: ${passed}/${total} contracts`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
