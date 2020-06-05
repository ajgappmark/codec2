% ofdm_ldpc_tx.m
% David Rowe April 2017
%
% File based ofdm tx with LDPC encoding and interleaver.  Generates a
% file of ofdm samples, including optional channel simulation.

#{
  Examples:
 
  i) 10 seconds, AWGN channel at (coded) Eb/No=3dB

    octave:4> ofdm_ldpc_tx('awgn_ebno_3dB_700d.raw', "700D", 10, 3);

  ii) 10 seconds, HF channel at (coded) Eb/No=6dB

    ofdm_ldpc_tx('hf_ebno_6dB_700d.raw', "700D", 10, 6, 'hf');
#}


function ofdm_ldpc_tx(filename, mode="700D", Nsec, EbNodB=100, channel='awgn', freq_offset_Hz=0)
  ofdm_lib;
  ldpc;
  gp_interleaver;

  % init modem

  config = ofdm_init_mode(mode);
  states = ofdm_init(config);
  ofdm_load_const;

  % some constants used for assembling modem frames
  
  [code_param Nbitspercodecframe Ncodecframespermodemframe] = codec_to_frame_packing(states, mode);

  % Generate fixed test frame of tx bits and run OFDM modulator

  Npackets = round(Nsec/states.Tpacket);

  % OK generate a modem frame using random payload bits

  if strcmp(mode, "700D")
    payload_bits = round(ofdm_rand(code_param.data_bits_per_frame)/32767);
  elseif strcmp(mode, "2020")
    payload_bits = round(ofdm_rand(Ncodecframespermodemframe*Nbitspercodecframe)/32767);
  elseif strcmp(mode, "data")
    payload_bits = round(ofdm_rand(code_param.data_bits_per_frame)/32767);
  end
  [frame_bits bits_per_frame] = assemble_frame(states, code_param, mode, payload_bits, Ncodecframespermodemframe, Nbitspercodecframe);
   
  % modulate to create symbols and interleave
  
  tx_bits = tx_symbols = [];
  tx_bits = [tx_bits payload_bits];
  for b=1:2:bits_per_frame
    tx_symbols = [tx_symbols qpsk_mod(frame_bits(b:b+1))];
  end
  assert(gp_deinterleave(gp_interleave(tx_symbols)) == tx_symbols);
  tx_symbols = gp_interleave(tx_symbols);
  
  % generate txt symbols
 
  txt_bits = zeros(1,Ntxtbits);
  txt_symbols = [];
  for b=1:2:length(txt_bits)
    txt_symbols = [txt_symbols qpsk_mod(txt_bits(b:b+1))];
  end

  % assemble interleaved modem frames that include UW and txt symbols
  
  modem_frame = assemble_modem_frame_symbols(states, tx_symbols, txt_symbols);
  atx = ofdm_txframe(states, modem_frame); tx = [];
  for f=1:Npackets
    tx = [tx atx];
  end
  % a few empty frames of samples os Rx can finish it's processing
  tx = [tx zeros(1,2*Nsamperframe)]; 
  Nsam = length(tx);

  % channel simulation

  EsNo = rate * bps * (10 .^ (EbNodB/10));
  variance = 1/(M*EsNo/2);
  woffset = 2*pi*freq_offset_Hz/Fs;

  SNRdB = EbNodB + 10*log10(Nc*bps*Rs*rate/3000);
  printf("Packets: %3d EbNo: %3.1f dB  SNR(3k) est: %3.1f dB  foff: %3.1fHz",
         Npackets, EbNodB, SNRdB, freq_offset_Hz);

  % set up HF model ---------------------------------------------------------------

  if strcmp(channel, 'hf') || strcmp(channel, 'hfgood')
    randn('seed',1);

    % ITUT "poor" or "moderate" channels

    if strcmp(channel, 'hf')
      dopplerSpreadHz = 1; path_delay_ms = 1;
    else
      % "hfgood"
      dopplerSpreadHz = 0.1; path_delay_ms = 0.5;
    end
    
    path_delay_samples = path_delay_ms*Fs/1000;
    printf(" Doppler Spread: %3.2f Hz Path Delay: %3.2f ms %d samples\n", dopplerSpreadHz, path_delay_ms, path_delay_samples);

    % generate same fading pattern for every run

    randn('seed',1);

    spread1 = doppler_spread(dopplerSpreadHz, Fs, (Nsec*(M+Ncp)/M)*Fs*1.1);
    spread2 = doppler_spread(dopplerSpreadHz, Fs, (Nsec*(M+Ncp)/M)*Fs*1.1);
   
    % sometimes doppler_spread() doesn't return exactly the number of samples we need
 
    assert(length(spread1) >= Nsam, "not enough doppler spreading samples");
    assert(length(spread2) >= Nsam, "not enough doppler spreading samples");
  end

  rx = tx;

  if strcmp(channel, 'hf') || strcmp(channel, 'hfgood')
    rx  = tx(1:Nsam) .* spread1(1:Nsam);
    rx += [zeros(1,path_delay_samples) tx(1:Nsam-path_delay_samples)] .* spread2(1:Nsam);

    % normalise rx power to same as tx

    nom_rx_pwr = 2/(Ns*(M*M)) + Nc/(M*M);
    rx_pwr = var(rx);
    rx *= sqrt(nom_rx_pwr/rx_pwr);
  end

  rx = rx .* exp(j*woffset*(1:Nsam));

  % note variance/2 as we are using real() operator, mumble,
  % reflection of -ve freq to +ve, mumble, hand wave

  noise = sqrt(variance/2)*0.5*randn(1,Nsam);
  rx = real(rx) + noise;
  printf("measured SNR: %3.2f dB\n", 10*log10(var(real(tx))/var(noise)) + 10*log10(4000) - 10*log10(3000));

  % adjusted by experiment to match rms power of early test signals

  frx=fopen(filename,"wb"); fwrite(frx, states.amp_scale*rx, "short"); fclose(frx);
endfunction
