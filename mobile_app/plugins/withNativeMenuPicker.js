const { withXcodeProject } = require('@expo/config-plugins');
const path = require('path');

/**
 * Expo Config Plugin: Injects NativeMenuPicker Swift/ObjC files
 * into the Xcode project compile sources so UIMenu renders natively.
 */
function withNativeMenuPicker(config) {
  return withXcodeProject(config, async (config) => {
    const xcodeProject = config.modResults;
    const targetName = 'mobileapp';

    // Find the main target's PBXNativeTarget
    const targets = xcodeProject.pbxNativeTargetSection();
    let mainTargetKey;
    for (const key in targets) {
      if (targets[key].name === targetName) {
        mainTargetKey = key;
        break;
      }
    }

    // Add Swift file
    const swiftPath = path.join(targetName, 'NativeMenuPicker.swift');
    xcodeProject.addSourceFile(swiftPath, null, 
      xcodeProject.findPBXGroupKey({ name: targetName }) ||
      xcodeProject.findPBXGroupKey({ path: targetName })
    );

    // Add ObjC bridge file
    const objcPath = path.join(targetName, 'NativeMenuPickerManager.m');
    xcodeProject.addSourceFile(objcPath, null, 
      xcodeProject.findPBXGroupKey({ name: targetName }) ||
      xcodeProject.findPBXGroupKey({ path: targetName })
    );

    return config;
  });
}

module.exports = withNativeMenuPicker;
