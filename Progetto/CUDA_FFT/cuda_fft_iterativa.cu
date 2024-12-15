#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <cuda_runtime.h>

#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"


#define SAMPLE_RATE 44100
#define PI 3.14159265358979323846

typedef struct {
    double real;
    double imag;
} complex;

complex prodotto_tra_complessi(complex a, complex b) {
    complex result;

    result.real = a.real*b.real - a.imag*b.imag;
    result.imag = a.real*b.imag + a.imag*b.real;

    return result;
}

// Funzione strana che ho trovato, che mi permette di ottenere il bit reverse order degli indici
// dei campioni della trasformata  in maniera efficiente O(log n).
// es. indice a 8 bit = 5:
//  5 = 00000101   ->  reversed = 10100000 = 160 
uint32_t reverse_bits(uint32_t x) {
    // 1. Swap the position of consecutive bits
    // 2. Swap the position of consecutive pairs of bits
    // 3. Swap the position of consecutive quads of bits
    // 4. Continue this until swapping the two consecutive 16-bit parts of x
    
    /*
        Primo scambio:
        0xaaa... = 1010-1010-... = bit pari; 0x555... = 0101-0101... bit dispari; 
        - nel primo gruppo seleziono i bit pari e li sposto a destra di una posizione
        - nel secondo gruppo selezioni i bit dispari e li sposto a sinistra di una posizione
        - facendo infine l'or dei due gruppi ottengo i la stringa di bit con le posizioni pari e dispari scambiate

        Lo stesso procedimento si ripete sotto
    */
    x = ((x & 0xaaaaaaaa) >> 1) | ((x & 0x55555555) << 1);  
    // 0xccc... = 1100-1100-... = coppie di bit pari; 0x333... = 0011-0011... coppie di bit dispari; 
    x = ((x & 0xcccccccc) >> 2) | ((x & 0x33333333) << 2);
    // 0xf0f0... = 11110000-... = quadruple di bit pari; 0x0f0f... = 00001111 ... quadruple di bit dispari; 
    x = ((x & 0xf0f0f0f0) >> 4) | ((x & 0x0f0f0f0f) << 4);
    // stessa cosa con gruppi da 8
    x = ((x & 0xff00ff00) >> 8) | ((x & 0x00ff00ff) << 8);
    return (x >> 16) | (x << 16);
}

void convert_to_complex(short *input, complex *output, int N) {
    for (int i = 0; i < N; i++) {
        output[i].real = (double)input[i];
        output[i].imag = 0.0;
    }
}

void convert_to_short(complex *input, short *output, int N) {
    for (int i = 0; i < N; i++) {
        output[i] = (short)round(input[i].real); 
    }
}



int fft_iterativa(complex *input, complex *output, int N) {
    if (N & (N - 1)) {
        fprintf(stderr, "N=%u deve essere una potenza di due\n", N);

        return -1;
    }

    int num_stadi = (int) log2f((float) N);

    for (uint32_t i = 0; i < N; i++) {
        uint32_t rev = reverse_bits(i);
        rev = rev >> (32 - num_stadi);

        output[i] = input[rev];
    }

    for (int stadio = 1; stadio <= num_stadi; stadio++) {
        int N_stadio_corrente = 1 << stadio;
        int N_stadio_corrente_mezzi = N_stadio_corrente / 2;

        double phi = -2.0*PI / N_stadio_corrente;
        complex twiddle = {
            cos(phi),
            sin(phi)
        };

        for (uint32_t k = 0; k < N; k += N_stadio_corrente) {
            complex twiddle_factor = {1, 0};

            for (int j = 0; j < N_stadio_corrente_mezzi; j++) {
                complex a = output[k + j];
                complex b = prodotto_tra_complessi(twiddle_factor, output[k + j + N_stadio_corrente_mezzi]);

                // Compute pow(twiddle, j)
                twiddle_factor = prodotto_tra_complessi(twiddle_factor, twiddle);

                // calcolo trasformata
                output[k + j].real = a.real + b.real;
                output[k + j].imag = a.imag + b.imag;
                // simmetria per la seconda metà
                output[k + j + N_stadio_corrente_mezzi].real = a.real - b.real;
                output[k + j + N_stadio_corrente_mezzi].imag = a.imag - b.imag;
            }
        }
    }

    return EXIT_SUCCESS;
}


// Kernel per calcolare le "farfalle"
__global__ void fft_stage(complex *output, int N, int N_stadio_corrente, int N_stadio_corrente_mezzi) {
    int thread_id = blockIdx.x * blockDim.x + threadIdx.x;

    if (thread_id >= N / 2) return;

    int k = (thread_id / N_stadio_corrente_mezzi) * N_stadio_corrente;
    int j = thread_id % N_stadio_corrente_mezzi;

    double phi = -2.0 * M_PI * j / N_stadio_corrente;
    complex twiddle_factor = {cos(phi), sin(phi)};

    complex a = output[k + j];
    complex b = prodotto_tra_complessi(twiddle_factor, output[k + j + N_stadio_corrente_mezzi]);

    output[k + j].real = a.real + b.real;
    output[k + j].imag = a.imag + b.imag;

    output[k + j + N_stadio_corrente_mezzi].real = a.real - b.real;
    output[k + j + N_stadio_corrente_mezzi].imag = a.imag - b.imag;
}

// Funzione principale FFT su GPU
void fft_iterativa_cuda(complex *input, complex *output, int N) {
    // Controllo che N sia una potenza di 2
    if (N & (N - 1)) {
        fprintf(stderr, "N=%u deve essere una potenza di due\n", N);
        return;
    }

    int num_stadi = (int)log2f((float)N);

    // Alloca memoria sulla GPU
    complex *d_output;
    cudaMalloc((void **)&d_output, N * sizeof(complex));

    // Copia input nell'output (con bit-reversal)
    complex *d_input;
    cudaMalloc((void **)&d_input, N * sizeof(complex));
    cudaMemcpy(d_input, input, N * sizeof(complex), cudaMemcpyHostToDevice);

    for (int i = 0; i < N; i++) {
        uint32_t rev = reverse_bits(i) >> (32 - num_stadi);
        cudaMemcpy(&d_output[rev], &d_input[i], sizeof(complex), cudaMemcpyDeviceToDevice);
    }

    cudaFree(d_input);

    // Configurazione dei blocchi e dei thread
    int threads_per_block = 256;
    int num_threads = N / 2;
    int num_blocks = (num_threads + threads_per_block - 1) / threads_per_block;

    // Lancia i kernel per ogni stadio
    for (int stadio = 1; stadio <= num_stadi; stadio++) {
        int N_stadio_corrente = 1 << stadio;
        int N_stadio_corrente_mezzi = N_stadio_corrente / 2;

        fft_stage<<<num_blocks, threads_per_block>>>(d_output, N, N_stadio_corrente, N_stadio_corrente_mezzi);
        cudaDeviceSynchronize();
    }

    // Copia il risultato indietro sulla CPU
    cudaMemcpy(output, d_output, N * sizeof(complex), cudaMemcpyDeviceToHost);

    // Libera memoria
    cudaFree(d_output);
}


// NB: nota come si praticamente uguale alla fft se non per il segno + dei twiddle 
void ifft_inplace_recursive(complex *input, complex *output, int step, int N) {
    if (N == 1) {
        output[0] = input[0];
        return;
    }

    // Calcola la IFFT sui sotto-array pari e dispari
    ifft_inplace_recursive(input, output, step*2, N/2);
    ifft_inplace_recursive(input + step, output + N/2, step*2, N/2); 

    // Combina i risultati
    for (int k = 0; k < N/2; k++) {
        double phi = 2*PI*k / N; // Cambia il segno per la IFFT
        complex twiddle = {
            cos(phi),
            sin(phi)
        };

        complex even = output[k];

        complex temp = {
            twiddle.real * output[k + N/2].real - twiddle.imag * output[k + N/2].imag,
            twiddle.real * output[k + N/2].imag + twiddle.imag * output[k + N/2].real
        };

        output[k].real = even.real + temp.real;
        output[k].imag = even.imag + temp.imag;
        //relazione simmetrica
        output[k + N/2].real = even.real - temp.real;
        output[k + N/2].imag = even.imag - temp.imag;
    }
}

void ifft_inplace(complex *input, complex *output, int N) {
    ifft_inplace_recursive(input, output, 1, N);

    // Non scordarti di normalizzare
    // NB: a quanto pare è importante che la normalizzazione avvenga soltanto alla fine di tutto
    for (int i = 0; i < N; i++) {
        output[i].real /= N;
        output[i].imag /= N;
    }
}



int main() {
    const char* FILE_NAME = "test_voce.wav";
    drwav wav_in;
    
    if (!drwav_init_file(&wav_in, FILE_NAME, NULL)) {
        fprintf(stderr, "Errore nell'aprire il file %s.wav.\n", FILE_NAME);
        return 1;
    }

    size_t num_samples = wav_in.totalPCMFrameCount * wav_in.channels;
    printf("NUMERO DI CAMPIONI NEL FILE AUDIO SCELTO: %ld; -> %0.2f secondi\n\n", num_samples, (float)num_samples/SAMPLE_RATE);

    printf("\nSchiaccia un tasto per avviare...\n");
    getchar();

    // importante avere una potenza di 2
    int padded_samples = 1 << (int)ceil(log2(num_samples));
    if (padded_samples > num_samples) {
        num_samples = padded_samples;
    }

    // Allocazione del buffer per i dati audio (PCM a 16 bit)
    short* signal_samples = (short*)malloc(num_samples * sizeof(short));
    if (signal_samples == NULL) {
        fprintf(stderr, "Errore nell'allocazione della memoria.\n");
        return 1;
    }
    // Allocazione del buffer per i dati audio (PCM a 16 bit) convertiti in numeri complessi
    complex* complex_signal_samples = (complex*)malloc(num_samples * sizeof(complex));
    if (complex_signal_samples == NULL) {
        fprintf(stderr, "Errore nell'allocazione della memoria.\n");
        return 1;
    }
    // Allocazione del buffer per le sinusoidi della FFT
    complex* fft_samples = (complex*)malloc(num_samples * sizeof(complex));
    if (fft_samples == NULL) {
        fprintf(stderr, "Errore nell'allocazione della memoria.\n");
        return 1;
    }

    // Lettura dei dati audio dal file di input
    size_t frames_read = drwav_read_pcm_frames_s16(&wav_in, wav_in.totalPCMFrameCount, signal_samples);
    if (frames_read != wav_in.totalPCMFrameCount) {
        fprintf(stderr, "Errore durante la lettura dei dati audio.\n");
        return 1;
    }

    drwav_uninit(&wav_in); 

    // calcolo la FFT
    convert_to_complex(signal_samples, complex_signal_samples, num_samples);
    fft_iterativa(complex_signal_samples, fft_samples, num_samples);

    // Calcola e salvo l'ampiezza per ciascuna frequenza
    FILE *output_file = fopen("amplitude_spectrum.txt", "w");
    if (output_file == NULL) {
        fprintf(stderr, "Errore nell'aprire il file di output.\n");
        return 1;
    }

    for (int i = 0; i < num_samples; i++) {
        double amplitude = sqrt(fft_samples[i].real*fft_samples[i].real + fft_samples[i].imag*fft_samples[i].imag);
        double frequency = (double)i * SAMPLE_RATE / num_samples;

        fprintf(output_file, "%lf %lf\n", frequency, amplitude);

        if(amplitude > 1000000) {
            printf("Frequenza: %lf sembra essere un componente utile del segnale\n", frequency);
        }
    }

    printf("I dati dello spettro sono stati scritti in 'amplitude_spectrum.txt'.\n");
    fclose(output_file);




    /* --- PARTE IFFT --- */

    

    // inizializzazione dati
    char generated_filename[100];   //dimensione arbitraria perchè non ho voglia
    sprintf(generated_filename, "IFFT-generated-%s", FILE_NAME);
    // mi assicuro di non imbrogliare ricopiando i dati di prima
    memset(signal_samples, 0, num_samples*sizeof(short));
    memset(complex_signal_samples, 0, num_samples);

    // Preparazione del formato del file di output
    drwav_data_format format_out;
    format_out.container = drwav_container_riff;
    format_out.format = DR_WAVE_FORMAT_PCM;
    format_out.channels = 1;              // Mono
    format_out.sampleRate = SAMPLE_RATE;  // Frequenza di campionamento
    format_out.bitsPerSample = 16;        // 16 bit per campione

    // Inizializzazione del file di output
    drwav wav_out;
    if (!drwav_init_file_write(&wav_out, generated_filename, &format_out, NULL)) {
        fprintf(stderr, "Errore nell'aprire il file di output %s.\n", generated_filename);
        return 1;
    }
    
    ifft_inplace(fft_samples, complex_signal_samples, num_samples);
    convert_to_short(complex_signal_samples, signal_samples, num_samples);

    // Scrittura dei dati audio nel file di output
    drwav_write_pcm_frames(&wav_out, num_samples, signal_samples);
    drwav_uninit(&wav_out); // Chiusura del file di output

    printf("File WAV %s creato con successo\n", generated_filename);

    free(signal_samples);
    free(complex_signal_samples);
    free(fft_samples);
}