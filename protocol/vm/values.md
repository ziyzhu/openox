# VM Values

Values crossing the portable VM boundary are JSON null, booleans, finite
numbers, strings, arrays, and string-keyed objects. Function arguments are
objects unless a function contract explicitly states otherwise.

Binary content crosses by an explicit artifact or encoded-data contract, never
as a language-runtime object. Undefined values, functions, cyclic structures,
nonfinite numbers, and implementation-native handles are not portable values.
