/* mars' openssl/opensslconf.h dispatches on __APPLE__/__ANDROID__/... and has no Linux branch; its
   Linux libcrypto.a was built with this configuration. Found first via -I mayhem/include. */
#include "../../../mars/openssl/include/openssl/opensslconf_linux_x86_64.h"
