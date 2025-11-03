#include <common.h>
#include <defs.h>

int main(int argc, char **argv){
  init_monitor(argc, argv);
  sdb_mainloop();
  return 0;
}
