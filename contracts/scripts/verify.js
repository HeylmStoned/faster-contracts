const { run } = require("hardhat");

/**
 * Contract Verification Script
 * 
 * Verifies all Diamond facets on block explorer.
 * Update DEPLOYMENT object with addresses from deploy script output.
 */

const DEPLOYMENT = {
    diamond: "",
    facets: {
        diamondCut: "",
        diamondLoupe: "",
        token: "",
        trading: "",
        graduation: "",
        fee: "",
        security: "",
        admin: "",
        erc6909: "",
        wrapper: ""
    },
    diamondInit: "",
    owner: ""
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
        "contracts/Diamond.sol:Diamond",
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
        if (await verify(
            DEPLOYMENT.diamondInit,
            "contracts/upgradeInitializers/DiamondInit.sol:DiamondInit"
        )) passed++;
    }

    console.log(`\nVerification Complete: ${passed}/${total} contracts`);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
