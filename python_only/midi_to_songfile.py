import mido
import numpy as np

filename = 'Never-Gonna-Give-You-Up-1.mid'
song_title = 'rickroll'

mid = mido.MidiFile(filename, clip=True)

deltatimes = np.array([x.time for x in mid.tracks[0]])
times = np.cumsum(deltatimes)

msg_list = np.array([x for x in mid.tracks[0]])

tempo_changes = np.array([[msg_list[i].tempo, times[i]] for i in range(len(times)) if msg_list[i].type == 'set_tempo'])

notelist = []

for track in mid.tracks:

	deltatimes = np.array([x.time for x in track])
	times = np.cumsum(deltatimes)

	msg_list = np.array([x for x in track])
	midi_notelist = np.array([[msg_list[i].note, (msg_list[i].velocity if msg_list[i].type=='note_on' else 0), times[i]] for i in range(len(times)) if (msg_list[i].type == 'note_on' or msg_list[i].type == 'note_off')])

	if len(midi_notelist) == 0: continue

	for note in set(midi_notelist[:,0]):

		on_mask = np.where((midi_notelist[:,0] == note) & (midi_notelist[:,1] != 0))
		off_mask = np.where((midi_notelist[:,0] == note) & (midi_notelist[:,1] == 0))

		start_times = midi_notelist[on_mask][:,2]
		durations = midi_notelist[off_mask][:,2] - midi_notelist[on_mask][:,2]

		notelist += [[start_times[i], durations[i], 2**((note-69)/12)*440] for i in range(len(start_times))]

notelist = np.array(sorted(notelist, key=lambda x: x[0]))

ticks_per_beat = mid.ticks_per_beat
last_tempo = tempo_changes[0,0]
bpm = mido.tempo2bpm(last_tempo)

last_tps = ticks_per_beat * bpm / 60

notelist = notelist.astype(np.dtype('float64'))

notelist[:,0] /= last_tps
notelist[:,1] /= last_tps

for tempo, start_time in tempo_changes:

	start_index = len(np.where(notelist[:,1] < start_time)[0])

	new_tps = ticks_per_beat * mido.tempo2bpm(tempo) / 60

	tps_ratio = last_tps/new_tps

	notelist[start_index:,0] *= tps_ratio
	notelist[start_index:,1] *= tps_ratio

	last_tps = new_tps
	last_tempo = tempo

notelist_string = '{' + ','.join(['"' + str(round(x[0],2)) + ',' + str(round(x[1],3)) + ',' + str(round(x[2],2)) + '"' for x in notelist]) + '}'

files_to_write = []
if len(notelist_string) > 26000:
	while len(notelist_string) > 26000:
		break_point = notelist_string[26000:].index('",')
		break_segment = notelist_string[:26000 + break_point + 1] + '}'
		files_to_write.append(break_segment)
		notelist_string = '{' + notelist_string[26000 + break_point + 2:]
	files_to_write.append(notelist_string)
else:
	files_to_write.append(notelist_string)

for i in range(len(files_to_write)):
	with open(song_title + ('_' + str(i) if len(files_to_write) > 1 else '') + '.song', 'w') as file:
		file.write(files_to_write[i])