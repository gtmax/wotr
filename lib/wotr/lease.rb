# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Wotr
  # Compact bare duration for composition ("… ago", "waited …"): "0s", "45s",
  # "12m", "2h 5m", "3d".
  module Duration
    module_function

    def human(seconds)
      s = [seconds.to_i, 0].max
      return "#{s}s" if s < 60

      m = s / 60
      return "#{m}m" if m < 60

      h = m / 60
      rem = m % 60
      return (rem.zero? ? "#{h}h" : "#{h}h #{rem}m") if h < 24

      d = h / 24
      "#{d}d"
    end
  end

  # A lease is a note stored next to a shared resource recording which worktree
  # holds it, when it was acquired, and when its ownership was last confirmed.
  #
  # Leases exist to make resource ownership *visible* and taking a resource
  # *non-silent*. They are bookkeeping only — the authoritative "is this resource
  # live right now" signal is still the resource's own `inquire` probe. A lease
  # adds identity (which worktree), timestamps (acquired / renewed), and a TTL so
  # an abandoned worktree's claim lapses on its own instead of blocking forever.
  Lease = Struct.new(
    :resource, :holder, :holder_branch, :acquired_at, :renewed_at, :ttl, :adopted,
    keyword_init: true
  ) do
    # Live = last confirmed within its TTL. A lapsed lease is kept for display
    # ("held by X, lapsed 3m ago") but no longer guards against being taken.
    def live?(now = Time.now.to_i)
      (now - renewed_at.to_i) < ttl.to_i
    end

    def age(now = Time.now.to_i)
      now - acquired_at.to_i
    end

    def since_renew(now = Time.now.to_i)
      now - renewed_at.to_i
    end

    # True when wotr never ran an acquire for this resource but observed it
    # already running (e.g. a server started by hand). Timestamps are then
    # "first seen", not "acquired".
    def adopted?
      adopted == true
    end
  end

  # File-backed, flock-guarded store of leases shared across every worktree of a
  # repository. Lives in the repo's shared wotr state dir (next to wotr.log), so
  # it survives deletion of any individual worktree.
  class LeaseStore
    FILENAME = "leases.json"

    DEFAULT_TTL = 30 * 60 # seconds

    def initialize(path)
      @path = path
    end

    def self.for_dir(state_dir)
      new(File.join(state_dir, FILENAME))
    end

    attr_reader :path

    # All leases keyed by resource name.
    def all
      read_data.each_with_object({}) do |(name, row), acc|
        acc[name] = to_lease(name, row)
      end
    end

    def get(name)
      row = read_data[name.to_s]
      row && to_lease(name.to_s, row)
    end

    # Record (or renew) a lease for `name` held by `holder`. If the same holder
    # already holds it, `acquired_at` is preserved and only `renewed_at` bumps —
    # a renewal, not a fresh acquisition.
    def acquire(name, holder:, holder_branch: nil, ttl: DEFAULT_TTL, now: Time.now.to_i)
      transaction do |data|
        existing = data[name.to_s]
        acquired = if existing && same_holder?(existing["holder"], holder)
                     existing["acquired_at"] || now
                   else
                     now
                   end
        data[name.to_s] = {
          "holder" => normalize(holder),
          "holder_branch" => holder_branch,
          "acquired_at" => acquired,
          "renewed_at" => now,
          "ttl" => ttl,
          "adopted" => false
        }
      end
      get(name)
    end

    # Bump `renewed_at` for a live/observed lease. Only renews when the recorded
    # holder still matches `holder` (guards against renewing someone else's lease
    # after a takeover). Returns true if a row was renewed.
    def renew(name, holder:, now: Time.now.to_i)
      transaction do |data|
        row = data[name.to_s]
        next false unless row && same_holder?(row["holder"], holder)

        row["renewed_at"] = now
        true
      end
    end

    # Record a lease for a resource wotr observed already running but never
    # acquired itself. Timestamps are "first seen". No-op if a row already exists.
    def adopt(name, holder:, holder_branch: nil, ttl: DEFAULT_TTL, now: Time.now.to_i)
      transaction do |data|
        next false if data[name.to_s]

        data[name.to_s] = {
          "holder" => normalize(holder),
          "holder_branch" => holder_branch,
          "acquired_at" => now,
          "renewed_at" => now,
          "ttl" => ttl,
          "adopted" => true
        }
        true
      end
    end

    def release(name)
      return false unless File.exist?(@path)

      transaction do |data|
        !!data.delete(name.to_s)
      end
    end

    # Release every lease held by `holder` (used when a worktree is deleted).
    # Returns the list of released resource names.
    def release_for_holder(holder)
      return [] unless File.exist?(@path)

      transaction do |data|
        released = data.select { |_, row| same_holder?(row["holder"], holder) }.keys
        released.each { |name| data.delete(name) }
        released
      end
    end

    private

    def to_lease(name, row)
      Lease.new(
        resource: name,
        holder: row["holder"],
        holder_branch: row["holder_branch"],
        acquired_at: row["acquired_at"],
        renewed_at: row["renewed_at"],
        ttl: row["ttl"] || DEFAULT_TTL,
        adopted: row["adopted"] == true
      )
    end

    def normalize(path)
      return path if path.nil?

      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    def same_holder?(a, b)
      return false if a.nil? || b.nil?

      normalize(a) == normalize(b)
    end

    def read_data
      return {} unless File.exist?(@path)

      File.open(@path, File::RDONLY) do |f|
        f.flock(File::LOCK_SH)
        parse(f.read)
      end
    rescue Errno::ENOENT
      {}
    end

    # Read-modify-write under an exclusive lock so concurrent worktrees don't
    # clobber each other's leases.
    def transaction
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        data = parse(f.read)
        result = yield data
        f.rewind
        f.truncate(0)
        f.write(JSON.pretty_generate(data))
        f.write("\n")
        result
      end
    end

    def parse(raw)
      return {} if raw.nil? || raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
