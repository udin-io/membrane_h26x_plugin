defmodule Membrane.H265.ScalingListTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.H265.{NALuParser, Parser}
  alias Membrane.Testing.{Pipeline, Sink, Source}

  # A camera's VPS and SPS. Bit 199 of the SPS is scaling_list_data_present_flag, the
  # last bit of the byte before @sps_tail, and it is 0 here. `ffmpeg -bsf:v
  # trace_headers` reads the fields in @fields_after_lists from this SPS.
  @vps <<64, 1, 12, 1, 255, 255, 1, 96, 0, 0, 3, 0, 0, 3, 0, 0, 3, 0, 0, 3, 0, 150, 172, 9>>
  @sps_head <<66, 1, 1, 1, 96, 0, 0, 3, 0, 0, 3, 0, 0, 3, 0, 0, 3, 0, 150, 160, 1, 64, 32, 5, 161,
              99, 107, 146>>
  @sps_tail <<83, 55, 1, 1, 1, 4, 0, 0, 70, 80, 0, 5, 126, 66, 132>>
  @announced_sps <<@sps_head::binary, 78, @sps_tail::binary>>

  @fields_after_lists [
    amp_enabled_flag: 0,
    sample_adaptive_offset_enabled_flag: 1,
    pcm_enabled_flag: 0,
    num_short_term_ref_pic_sets: 0,
    long_term_ref_pics_present_flag: 0,
    temporal_mvp_enabled_flag: 0,
    strong_intra_smoothing_enabled_flag: 1,
    vui_parameters_present_flag: 1,
    video_signal_type_present_flag: 1,
    vui_timing_info_present_flag: 1,
    num_units_in_tick: 4500,
    time_scale: 90_000
  ]

  # Three frames from x265 with a --scaling-list file, so every one of the 20 lists is
  # explicit, with negative deltas. @x265_fields_after_lists comes from
  # `ffmpeg -bsf:v trace_headers` on the same file.
  @x265_stream "test/fixtures/h265/input-3-320x240-scaling-lists.h265"
  @x265_fields_after_lists [
    pic_width_in_luma_samples: 320,
    pic_height_in_luma_samples: 240,
    amp_enabled_flag: 0,
    sample_adaptive_offset_enabled_flag: 1,
    pcm_enabled_flag: 0,
    num_short_term_ref_pic_sets: 0,
    long_term_ref_pics_present_flag: 0,
    temporal_mvp_enabled_flag: 1,
    strong_intra_smoothing_enabled_flag: 1,
    vui_parameters_present_flag: 1,
    aspect_ratio_idc: 1,
    video_format: 5,
    num_units_in_tick: 1,
    time_scale: 10
  ]

  defp ue(value) do
    length = Integer.digits(value + 1, 2) |> length()
    <<0::size(length - 1), value + 1::size(length)>>
  end

  defp se(value) when value > 0, do: ue(2 * value - 1)
  defp se(value), do: ue(-2 * value)

  defp matrix_ids(3), do: [0, 3]
  defp matrix_ids(_size_id), do: Enum.to_list(0..5)

  defp predicted_list(), do: <<0::1, ue(0)::bitstring>>

  defp coefficient_count(size_id), do: min(64, Bitwise.bsl(1, 4 + 2 * size_id))

  # Deltas alternate in sign and in code length, so a miscount lands inside a code.
  defp explicit_list(size_id) do
    dc = if size_id > 1, do: se(-3), else: <<>>

    deltas =
      for i <- 1..coefficient_count(size_id), into: <<>> do
        se(if rem(i, 2) == 0, do: -i, else: i)
      end

    <<1::1, dc::bitstring, deltas::bitstring>>
  end

  defp lists(explicit_size_ids) do
    for size_id <- 0..3, _matrix_id <- matrix_ids(size_id), into: <<>> do
      if size_id in explicit_size_ids, do: explicit_list(size_id), else: predicted_list()
    end
  end

  # Each list copies one earlier in its size, so the copy's code grows past 1 bit.
  defp lists_copying_earlier_ones() do
    for size_id <- 0..3, {_id, index} <- Enum.with_index(matrix_ids(size_id)), into: <<>> do
      <<0::1, ue(index)::bitstring>>
    end
  end

  defp escape(<<0, 0, byte, rest::binary>>) when byte <= 3,
    do: <<0, 0, 3, escape(<<byte, rest::binary>>)::binary>>

  defp escape(<<byte, rest::binary>>), do: <<byte, escape(rest)::binary>>
  defp escape(<<>>), do: <<>>

  defp sps_with_lists(lists) do
    body = <<79, lists::bitstring, @sps_tail::binary>>
    padding = 8 - rem(bit_size(body), 8)
    <<@sps_head::binary, escape(<<body::bitstring, 0::size(padding)>>)::binary>>
  end

  defp parse_sps(sps) do
    {_vps, state} = NALuParser.parse(@vps, {nil, nil}, false, NALuParser.new(:annexb))
    {nalu, _state} = NALuParser.parse(sps, {nil, nil}, false, state)
    nalu
  end

  defp assert_fields(nalu, expected) do
    assert nalu.status == :valid

    assert Keyword.new(expected, fn {key, _value} -> {key, nalu.parsed_fields[key]} end) ==
             expected
  end

  defp x265_sps() do
    @x265_stream
    |> File.read!()
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global, :trim_all])
    |> Enum.find(&match?(<<0::1, 33::6, _rest::bitstring>>, &1))
  end

  test "an SPS without list data keeps its fields" do
    assert_fields(parse_sps(@announced_sps), @fields_after_lists)
  end

  test "lists predicted from a reference keep the fields after them" do
    nalu = parse_sps(sps_with_lists(lists([])))

    assert_fields(nalu, [{:scaling_list_data_present_flag, 1} | @fields_after_lists])
  end

  test "lists that copy an earlier list keep the fields after them" do
    nalu = parse_sps(sps_with_lists(lists_copying_earlier_ones()))

    assert_fields(nalu, [{:scaling_list_data_present_flag, 1} | @fields_after_lists])
  end

  for size_id <- 0..3 do
    test "explicit lists at size id #{size_id} keep the fields after them" do
      nalu = parse_sps(sps_with_lists(lists([unquote(size_id)])))

      assert_fields(nalu, [{:scaling_list_data_present_flag, 1} | @fields_after_lists])
    end
  end

  test "explicit lists at every size id keep the fields after them" do
    nalu = parse_sps(sps_with_lists(lists([0, 1, 2, 3])))

    assert_fields(nalu, [{:scaling_list_data_present_flag, 1} | @fields_after_lists])
  end

  test "an x265 SPS with 20 explicit lists matches what FFmpeg reads" do
    nalu = parse_sps(x265_sps())

    assert_fields(nalu, [{:scaling_list_data_present_flag, 1} | @x265_fields_after_lists])
  end

  test "the parser takes the stream format from an SPS with explicit lists" do
    pipeline =
      Pipeline.start_supervised!(
        spec:
          child(:source, %Source{
            output: [File.read!(@x265_stream)],
            stream_format: %Membrane.RemoteStream{type: :packetized}
          })
          |> child(:parser, Parser)
          |> child(:sink, Sink)
      )

    assert_sink_stream_format(pipeline, :sink, %Membrane.H265{width: 320, height: 240})
    assert_end_of_stream(pipeline, :sink)
    Pipeline.terminate(pipeline)
  end
end
