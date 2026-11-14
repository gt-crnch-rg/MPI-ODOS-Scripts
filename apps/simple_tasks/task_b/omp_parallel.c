#include <omp.h> 
#include <stdio.h>

int main()
{
#pragma omp target
#pragma omp parallel
	puts("Hey! OpenMP also works on the DPU...");

	return 0;
}
