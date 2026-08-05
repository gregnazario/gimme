#ifndef GIMME_CTX_BOX_H
#define GIMME_CTX_BOX_H

#include <stdint.h>

// Opaque pointer carried inside a Lua userdata; points at the Swift Sandbox.
typedef struct gimme_ctx_box {
    void *sandbox;  // Unmanaged<Sandbox>.toOpaque()
} gimme_ctx_box;

#endif
