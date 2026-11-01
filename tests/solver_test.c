#include "../Sources/Solver.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void){
 int32_t b[16]={2,2,2,2}, out[16]; assert(solver_move(b,0,out)); assert(out[0]==4&&out[1]==4&&out[2]==0&&out[3]==0);
 assert(solver_move(b,1,out)); assert(out[2]==4&&out[3]==4);
 int32_t up[16]={2,0,0,0, 2,0,0,0}; assert(solver_move(up,3,out)); assert(out[12]==4);
 int32_t none[16]={0}; assert(solver_best(none)==-1);
 int32_t full[16]={2,4,2,4,4,2,4,2,2,4,2,4,4,2,4,2}; assert(solver_best(full)==-1);
 int32_t d[16]={2,2}; int best=solver_best(d); assert(best>=0&&best<4); assert(solver_move(d,best,out)); puts("solver tests passed");
}
