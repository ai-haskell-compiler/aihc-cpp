/*
 * A deliberately empty stand-in for the cabal_macros.h that Cabal generates,
 * for the benchmark corpus only.
 *
 * Cabal writes one of these per package during a build, defining VERSION_ and
 * MIN_VERSION_ for that package's own dependencies. A bare source tree has
 * none, so a module that includes it by name fails to resolve the include —
 * and because the three preprocessors disagree about whether an unresolvable
 * include is fatal, that turned into a difference in the failure counts that
 * said nothing about preprocessing.
 *
 * This file exists so the include resolves. It defines nothing on purpose.
 *
 * A snapshot-wide file with a MIN_VERSION_ for all 3441 packages was tried and
 * is not here, for two reasons. Resolving the include is nearly all of the
 * benefit: with the macros defined, only two more modules preprocessed
 * cleanly, because an undefined macro in an #if simply takes the other branch
 * rather than failing. And it cannot be pre-included the way a real build
 * pre-includes cabal_macros.h: even pruned to the packages the corpus names it
 * is 212KB against an average module of 12KB, which turned a 71MiB corpus into
 * 1.3GiB and made the benchmark measure macro-file parsing (3.26s to 69.56s).
 *
 * A real per-package cabal_macros.h is small because it holds only that
 * package's dependencies. A shared one cannot be, so this one holds nothing.
 */

#pragma once
