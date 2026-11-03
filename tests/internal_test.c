// Compile this file on its own: static internals are deliberately included.
#include "../Sources/Solver.c"
#include <assert.h>
#include <stdio.h>
static uint32_t state=0x952461u;
static uint32_t rnd(void){state^=state<<13;state^=state>>17;state^=state<<5;return state;}
int main(void){
 assert(DEPTH==4 && MAX_DEPTH==6 && NODE_BUDGET==200000 && SAMPLE_CELLS==4);
 assert(solver_spawn_value()==0);
 solver_set_spawn_value(4); assert(solver_spawn_value()==4);
 solver_set_spawn_value(3); assert(solver_spawn_value()==0);
 for(int t=0;t<10000;t++) {
   int32_t in[16], out[16]; uint8_t ranks[16],outRanks[16];
   for(int i=0;i<16;i++){int r=(int)(rnd()%11);r=(r<4)?0:r-3;ranks[i]=(uint8_t)r;in[i]=r?(1<<r):0;}
   for(int d=0;d<4;d++){int a=solver_move(in,d,out), b=move_rank(ranks,d,outRanks);assert(a==b);for(int i=0;i<16;i++)assert(out[i]==(outRanks[i]?(1<<outRanks[i]):0));}
 }
 int32_t in[16]={512,256,128,64,4,8,16,32,0,0,0,0,0,0,0,0},saved[16],out[16];memcpy(saved,in,sizeof(in));
 int a=solver_best(in), b=solver_best(in);assert(a==b && a>=0 && a<4 && solver_move(in,a,out));assert(!memcmp(in,saved,sizeof(in)));
 // Regression: two equal highest tiles must be joined, not parked next to each
 // other (実機で「2048 が隣り合っているのに合体しない」が起きた)。
 int32_t pairs[2][16]={
   {2048,2048,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0},
   {2048,2048,1024,512, 256,256,64,32, 16,8,4,2, 0,0,4,0},
 };
 for(int t=0;t<2;t++){
   int32_t before=pairs[t][0], d=solver_best(pairs[t]), top=0;
   assert(d>=0 && d<4 && solver_move(pairs[t],d,out));
   for(int i=0;i<16;i++) if(out[i]>top) top=out[i];
   assert(top>before);
 }
 puts("rank simulation and deterministic search tests passed (10000 boards)");
}
