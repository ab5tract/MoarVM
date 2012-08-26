/* Representation used by VM-level strings. */

struct _MVMStringBody;
typedef MVMuint8 MVMStrandIndex;
/* An entry in the strands table of a rope. */
typedef struct _MVMStrand {
    /* The offset to compare the desired index against. */
    MVMuint64 compare_offset;
    
    /* The string to which this strand refers. */
    struct _MVMString *string;
    
    /* The offset into the referred string. The length
        is calculated by subtracting the compare_offset
        from the compare_offset of the next entry. */
    MVMuint64 string_offset;
    
    /* The destinations in the table to branch when
        binary searching for an offset into the string. 
        If they are equal, it means use the compare_offset
        string at that strand's row. */
    /* The index of the strand table for lower than. */
    MVMStrandIndex lower_index;
    
    /* The index of the strand table for higher than or equal to. */
    MVMStrandIndex higher_index;
} MVMStrand;

#define MVM_STRING_CODES_BITS 56
#define MVM_STRING_TYPE_INT32 0
#define MVM_STRING_TYPE_UINT8 (1ULL << MVM_STRING_CODES_BITS)
#define MVM_STRING_TYPE_ROPE (2ULL << MVM_STRING_CODES_BITS)
#define MVM_STRING_TYPE_MASK (3ULL << MVM_STRING_CODES_BITS)
#define MVM_STRING_CODES_MASK ((1ULL << MVM_STRING_CODES_BITS) - 1)

typedef struct _MVMStringBody {
    /* The string data (signed integer or unsigned char array
        of graphemes or strands). */
    union {
        /* Array of the codepoints in a string. */
        MVMint32 *int32s;
        /* An optimization so strings containing only codepoints
            that fit in 8 bits can take up only 1 byte each */
        MVMuint8 *uint8s;
    } data;
    
    /* The number of graphemes that make up the string
        (and in turn, the length of data in terms of the
        number of 32-bit integers or bytes it has, or when
        a rope, the value of the last MVMStrand's compare_offset. */
    MVMuint64 graphs;
    
    /* The bottom 56 bits is the number of codepoints the string is
        made up of were it not in NFG form. Lazily populated and cached.
        (No, I don't think we'll have 32PB of memory anytime soon.)
       The top 8 bits are flags about the string: 
            Lowest 2 bits: type of string: uint8, int32, or Rope
     */
    MVMuint64 codes;
    
    /* For a non-rope that qualified as large during a particular
        GC run, a array of MVMStrand* that point to this large string.
        Built up during gc_mark */
    /* For a rope, An array of MVMStrand, each representing a
        segment of the string, up to the last one, which
        represents the end of the string and has values
        compare_offset=#graphs, string=null, string_offset=0,
        lower_index=0, higher_index=0.  The first one has
        compare_offset=0, and lower/higher_index=midpoint of
        strand array. */
    MVMStrand *strands;
} MVMStringBody;
typedef struct _MVMString {
    MVMObject common;
    MVMStringBody body;
} MVMString;

/* Function for REPR setup. */
MVMREPROps * MVMString_initialize(MVMThreadContext *tc);
