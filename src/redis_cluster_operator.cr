require "kubernetes"
require "redis"
require "log"

Log.setup_from_env

LOG = Log.for("redis-cluster-operator")

Kubernetes.import_crd "k8s/crd-redis-cluster.yaml"
Kubernetes.import_crd "k8s/crd-redis-db.yaml"

k8s = Kubernetes::Client.new(
  server: URI.parse(ENV["K8S"]? || "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_SERVICE_PORT"]}"),
  token: ENV["TOKEN"]? || File.read("/var/run/secrets/kubernetes.io/serviceaccount/token"),
  certificate_file: ENV["CA_CERT"]? || "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
)

spawn do
  k8s.watch_redisclusters do |watch|
    cluster = watch.object
    namespace = cluster.metadata.namespace
    name = cluster.metadata.name

    case watch
    when .added?, .modified?
      apply k8s, cluster
    when .deleted?
      k8s.delete_service(namespace: namespace, name: "#{name}-master")
      k8s.delete_service(namespace: namespace, name: "#{name}-replica")

      k8s.redisdbs(namespace: namespace, label_selector: "redis-cluster=#{name}").each do |redis|
        k8s.delete_redisdb(namespace: namespace, name: redis.metadata.name)
      end
    end
  rescue ex
    error ex
  end
  LOG.error { "Exited RedisCluster watch" }
end

spawn do
  k8s.watch_redisdbs do |watch|
    resource = watch.object

    case watch
    when .added?, .modified?
      apply k8s, resource
    when .deleted?
      k8s.delete_pod(
        namespace: resource.metadata.namespace,
        name: resource.metadata.name,
      )
    end
  rescue ex
    error ex
  end
  LOG.error { "Exited RedisDB watch" }
end

spawn do
  k8s.watch_pods(labels: "app.kubernetes.io/managed-by=redis-cluster-operator") do |watch|
    # ...
  end
end

loop do
  sleep 5.seconds

  k8s.redisclusters(namespace: nil).each do |cluster|
    reconcile_step k8s, cluster
    # namespace = cluster.metadata.namespace
    # name = cluster.metadata.name
    # k8s.redisdbs(namespace: namespace, label_selector: "redis-cluster=#{name},redis-cluster-role=master").each do |redis|
    #   if pod = k8s.pod(namespace: namespace, name: redis.metadata.name)
    #     pp master: pod.status["podIP"]
    #   else
    #     LOG.warn { "No master pod for #{namespace}/#{name}. Failing over..." }
    #     if new_master = k8s.redisdbs(namespace: namespace, label_selector: "redis-cluster=#{name},redis-cluster-role=replica").first?
    #       new_master_name = new_master.metadata.name
    #       LOG.warn { "Failing over to #{namespace}/#{new_master_name}..." }
    #       if new_master_pod = k8s.pod(namespace: namespace, name: new_master_name)
    #         uri = URI.parse("redis://#{new_master_pod.status["podIP"]}/")
    #         LOG.warn { "Connecting to #{namespace}/#{new_master_pod.metadata.name} (#{uri})..." }
    #         r = Redis::Client.new(uri)
    #         LOG.warn { r.run(%w[replicaof no one]).inspect }
    #         r.close
    #         LOG.warn { "RedisDB #{namespace}/#{new_master_name} server has taken over as cluster master" }
    #       end

    #       LOG.warn { "Patching RedisDB #{namespace}/#{new_master_name} to become the master instance..." }
    #       k8s.patch_redisdb(
    #         namespace: namespace,
    #         name: new_master_name,
    #         metadata: {
    #           annotations: {"redis-replicaof": "NO ONE"},
    #           labels:      {"redis-cluster-role": "master"},
    #         }
    #       )
    #     end
    #   end
    # end
  end
rescue ex
  error ex
end

def apply(k8s, cluster : Kubernetes::Resource(RedisCluster))
  instance = cluster.metadata.name
  replicas = cluster.spec.replicas

  k8s.apply_service(
    metadata: {
      namespace: cluster.metadata.namespace,
      name:      "#{cluster.metadata.name}-master",
    },
    spec: {
      selector: {
        "redis-cluster":      instance,
        "redis-cluster-role": "master",
      },
      ports: { {port: 6379} },
    },
  )
  k8s.apply_service(
    metadata: {
      namespace: cluster.metadata.namespace,
      name:      "#{cluster.metadata.name}-replica",
    },
    spec: {
      selector: {
        "redis-cluster":      instance,
        "redis-cluster-role": "replica",
      },
      ports: { {port: 6379} },
    },
  )
end

def apply(k8s, resource : Kubernetes::Resource(RedisDB))
  metadata = resource.metadata
  redis = resource.spec
  return unless instance = metadata.labels["redis-cluster"]?
  role = metadata.labels["redis-cluster-role"]

  if role == "replica"
    redis_args = "--replicaof #{instance}-master 6379"
  else
    redis_args = ""
  end

  k8s.apply_pod(
    metadata: {
      name:      metadata.name,
      namespace: metadata.namespace,
      labels:    {
        "redis":                        "#{metadata.namespace}.#{metadata.name}",
        "redis-cluster":                instance,
        "redis-cluster-role":           role,
        "app.kubernetes.io/managed-by": "redis-cluster-operator",
      },
    },
    spec: {
      restartPolicy: "Never",
      containers:    [
        {
          name:  "redis",
          image: "redis/redis-stack-server",
          env:   {
            {
              name:  "REDIS_ARGS",
              value: redis_args,
            },
          },
          ports:         { {containerPort: 6379} },
          livenessProbe: {
            exec:                {command: %w[redis-cli get foo]},
            initialDelaySeconds: 5,
            periodSeconds:       3,
          },
        },
      ],
    },
  )
end

def reconcile_step(k8s, cluster : Kubernetes::Resource(RedisCluster))
  instance = cluster.metadata.name
  replicas = cluster.spec.replicas

  dbs = k8s.redisdbs(namespace: cluster.metadata.namespace, label_selector: "redis-cluster=#{instance}")

  if dbs.size < replicas
    index = dbs.size

    k8s.apply_redisdb(
      metadata: {
        name:      "#{cluster.metadata.name}-#{index}",
        namespace: cluster.metadata.namespace,
        labels:    {
          "app.kubernetes.io/name":       "redisdb",
          "app.kubernetes.io/instance":   "redisdb-#{cluster.metadata.name}-#{index}",
          "app.kubernetes.io/part-of":    "redis-cluster",
          "app.kubernetes.io/managed-by": "redis-cluster-operator",
          "app.kubernetes.io/created-by": "redis-cluster-operator",
          "redis-cluster":                instance,
          "redis-cluster-role":           "replica",
        },
        annotations: {
          "redis-replicaof": "#{cluster.metadata.name}-master",
        },
      },
      spec: {
        size: cluster.spec.size,
      },
    )
  elsif dbs.size > replicas
    k8s.redisdbs(namespace: cluster.metadata.namespace, label_selector: "redis-cluster=#{instance}").each do |redisdb|
      if (match = redisdb.metadata.name.match(/-(\d+)$/)) && (index = match[1]?)
        index = index.to_i
        if index > cluster.spec.replicas
          k8s.delete_redisdb(
            namespace: cluster.metadata.namespace,
            name: "#{cluster.metadata.name}-#{index}",
          )
        end
      end
    end
  end

  if dbs.none? { |db| db.metadata.labels["redis-cluster-role"]? == "master" }
    # FIXME: Find the one that has the best replication status if possible
    new_master = dbs.sample
    promote_to_master k8s, new_master
  end
end

def error(ex : Exception)
  LOG.error { ex }
  if trace = ex.backtrace?
    trace.each { |line| LOG.error { line } }
  end
end

def promote_to_master(k8s, db : Kubernetes::Resource(RedisDB))
  namespace = db.metadata.namespace
  name = db.metadata.name
  LOG.info { "Promoting RedisDB #{namespace}/#{name} to cluster master" }

  if (pod = k8s.pod(namespace: namespace, name: name)) && (ip = pod.status["podIP"]?)
    r = Redis::Client.new(URI.parse("redis://#{ip}"))
    begin
      r.run %w[replicaof no one]

      k8s.patch_redisdb(
        namespace: namespace,
        name: name,
        metadata: {
          labels: {
            "redis-cluster-role": "master",
          },
        },
      )
      apply k8s, db
    ensure
      r.close
    end
  else
    LOG.warn { "No pod for RedisDB #{namespace}/#{name}, cannot promote" }
  end
end
