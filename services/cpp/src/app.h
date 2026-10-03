// HTTP application: routes, auth middleware, handlers.
#pragma once

#include "config.h"
#include "db.h"

namespace app {

// Builds and runs the HTTP server (blocking). Returns process exit code.
int serve(const Config& cfg, db::Pool& pool);

}  // namespace app
