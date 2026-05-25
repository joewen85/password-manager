package com.example.passwordmanagernative.ui

object WindowLayoutPolicy {
    private const val ExpandedWidthDp = 700

    fun shouldUseTwoPaneLayout(
        widthDp: Int,
        hasSeparatingFold: Boolean,
    ): Boolean = widthDp >= ExpandedWidthDp || hasSeparatingFold
}
