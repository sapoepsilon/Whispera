// SPDX-License-Identifier: MIT
// Copyright (c) 2025-2026 Ismatulla Mansurov

import Foundation
import WhisperaRecipes

// The recipe model moved into `WhisperaRecipes` (WHI-94). These aliases keep
// the app's own spelling of the types so call sites that only *use* a recipe —
// the pill's post-action label, the HUD, the settings list — read the same as
// before and need no import of their own.
//
// Aliases rather than a re-export because Swift has no `@_exported` worth
// relying on here, and because naming them once, in one file, makes it obvious
// where the types actually live.
typealias Recipe = WhisperaRecipes.Recipe
typealias RecipeStep = WhisperaRecipes.RecipeStep
typealias LLMStepConfig = WhisperaRecipes.LLMStepConfig
typealias RecipeMatch = WhisperaRecipes.RecipeMatch
typealias RecipeMatcher = WhisperaRecipes.RecipeMatcher
typealias RecipeExecuting = WhisperaRecipes.RecipeExecuting
