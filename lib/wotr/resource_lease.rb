# frozen_string_literal: true

require_relative 'lease'

module Wotr
  # Reconciles the resource lease store against physical reality.
  #
  # The lease store records *who wotr thinks* holds a resource; a resource's
  # `inquire` script reports *who physically holds it right now*. This service
  # merges the two: the physical probe is authoritative for "is it live", and the
  # lease supplies identity + timestamps. Reconciling on every read keeps the
  # store honest (renewing confirmed leases, adopting servers started outside
  # wotr, clearing leases whose server has died) without any background daemon.
  class ResourceLease
    # A resolved live owner of a resource.
    #   path   — owning worktree path (or a raw path / "unknown" for a non-worktree owner)
    #   branch — owning worktree's branch, if known
    #   lease  — the reconciled Lease row (may be nil when a probe was inconclusive)
    Holder = Struct.new(:name, :path, :branch, :lease, keyword_init: true)

    def initialize(repository)
      @repo = repository
      @config = repository.config
      @store = repository.lease_store
    end

    # Current live holder of `name`, or nil if the resource is free.
    # Reconciles the lease store as a side effect (renew / adopt / clear).
    def current_holder(name, chdir: Dir.pwd, env: {})
      probe = probe(name, chdir: chdir, env: env)
      lease = @store.get(name)

      if probe[:owner]
        owner = probe[:owner]
        wt = worktree_for(owner)
        branch = wt&.branch
        lease = reconcile_owned(name, owner, branch, lease)
        Holder.new(name: name, path: owner, branch: branch || lease&.holder_branch, lease: lease)
      elsif probe[:conclusive]
        # Nothing is physically holding the resource. Any lease is stale.
        @store.release(name) if lease
        nil
      elsif lease&.live?
        # Couldn't probe (no/failed inquire); trust a still-live lease.
        wt = worktree_for(lease.holder)
        Holder.new(name: name, path: lease.holder, branch: lease.holder_branch || wt&.branch, lease: lease)
      end
    end

    # Record this worktree as the holder after a successful acquire.
    def record_acquire(name, holder:, holder_branch: nil)
      @store.acquire(name, holder: holder, holder_branch: holder_branch, ttl: @config.lease_ttl(name))
    end

    def release(name)
      @store.release(name)
    end

    def same_path?(a, b)
      return false if a.nil? || b.nil?

      normalize(a) == normalize(b)
    end

    private

    def reconcile_owned(name, owner, branch, lease)
      ttl = @config.lease_ttl(name)
      if lease && same_path?(lease.holder, owner)
        @store.renew(name, holder: owner)
      elsif lease
        # Physical owner differs from the recorded holder — the lease is stale
        # (a takeover wotr didn't record). Replace it with a fresh adoption.
        @store.release(name)
        @store.adopt(name, holder: owner, holder_branch: branch, ttl: ttl)
      else
        @store.adopt(name, holder: owner, holder_branch: branch, ttl: ttl)
      end
      @store.get(name)
    end

    # Returns { owner: path|nil, conclusive: Boolean }.
    # conclusive is true only when inquire ran and returned a definite owned/unowned.
    def probe(name, chdir:, env:)
      res = @config.resource(name)
      return { owner: nil, conclusive: false } unless res && res["inquire"]

      result = @config.run_inquire(name, env: env, chdir: chdir)
      return { owner: nil, conclusive: false } unless result[:ran] && result[:success]

      case result[:data]["status"]
      when "owned"
        { owner: map_owner(result[:data]["owner"]), conclusive: true }
      when "unowned"
        { owner: nil, conclusive: true }
      else
        { owner: nil, conclusive: false }
      end
    end

    # Map an inquire-reported owner path onto a known worktree path when possible,
    # so identity is stable regardless of how the script spelled the path.
    def map_owner(owner)
      return "unknown" if owner.nil? || owner.to_s.strip.empty?

      wt = worktree_for(owner)
      wt ? wt.path : normalize(owner)
    end

    def worktree_for(path)
      return nil if path.nil? || path == "unknown"

      @repo.worktree_containing(path)
    end

    def normalize(path)
      return path if path.nil?

      File.realpath(path)
    rescue Errno::ENOENT
      File.expand_path(path)
    end
  end
end
