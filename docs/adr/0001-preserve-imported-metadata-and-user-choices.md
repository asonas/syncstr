# Preserve imported metadata separately from user organization choices

Compilation albums need coherent membership without replacing their original artist credits or rewriting the audio files. Syncstr will retain imported metadata separately from explicit album membership and compilation overrides, with user choices taking precedence until removed; rescans may refresh imported values but must not erase those choices. This requires retaining more catalog information than a single flattened metadata view, but makes corrections reversible and lets organization travel between devices without synthesizing Various Artists or changing source tags.

This decision records an agreed design direction; it is not implemented behavior. See [the compilation data design](../compilation-data-design.md) for the complete retention policy and implementation follow-up.
