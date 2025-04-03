#include "moar.h"
#include "yyjson.h"

void decode_json_str_to_mvmhash(MVMThreadContext *tc, MVMSTable *st, void *jsonBuf) {
    MVMArrayBody *body = (MVMArrayBody*) jsonBuf;
    char *jsonContent = &body->slots.u8[body->start];
    uint64 jsonSize = (uint64) body->elems;
    yyjson_read_flag readFlags = YYJSON_READ_ALLOW_INF_AND_NAN | YYJSON_READ_BIGNUM_AS_RAW;

    yyjson_doc *doc = yyjson_read(jsonContent, jsonSize, readFlags);

    if (doc) {
        yyjson_val *root = yyjson_doc_get_root(doc);
        yyjson_obj_iter iter;
        yyjson_obj_iter_init(obj, &iter);

        yyjson_val *key, *val;
        while ((key = yyjson_obj_iter_next(&iter))) {
            val = yyjson_obj_iter_get_val(key);
            printf("%s: %s\n", yyjson_get_str(key), yyjson_get_type_desc(val));
        }
    } else {
       printf("read error (%u): %s at position: %ld\n", err.code, err.msg, err.pos);
    }

    yyjson_doc_free(doc);
}
