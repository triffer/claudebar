module.exports = {
  extends: ["@commitlint/config-conventional"],

  // Dependabot writes its own body: compare links that run past the 100-column
  // limit on a single unwrappable line. Its header is already conventional, so
  // skip the whole message rather than block the bump.
  ignores: [(message) => /^Signed-off-by: dependabot\[bot\] </m.test(message)],
};
