import com.googlecode.dex2jar.ir.expr.*;
import com.googlecode.dex2jar.ir.stmt.*;
import com.googlecode.dex2jar.ir.ts.RemoveLocalFromSSA;
import java.util.*;

/** Compare bounded propagation with independently computed graph reachability. */
public final class PhiMemoryTest {
    static void check(int[][] parents, int roots, boolean exhaustive) throws Exception {
        Local[] locals = new Local[parents.length];
        for (int i=0;i<locals.length;i++) locals[i]=Exprs.nLocal(i);
        var label = Stmts.nLabel(); label.phis = new ArrayList<>();
        for (int i=roots;i<locals.length;i++) {
            Value[] values = Arrays.stream(parents[i]).mapToObj(j -> locals[j]).toArray(Value[]::new);
            label.phis.add(Stmts.nAssign(locals[i], Exprs.nPhi(values)));
        }
        var replacements = new HashMap<Local,Local>();
        var method=RemoveLocalFromSSA.class.getDeclaredMethod("removeLoopFromPhi", List.class, Map.class);
        method.setAccessible(true);
        method.invoke(new RemoveLocalFromSSA(), new ArrayList<>(List.of(label)), replacements);
        for (int i=roots;i<locals.length;i++) {
            int expected = 0;
            if (exhaustive) {
                var found=new HashSet<Integer>(); var seen=new HashSet<Integer>(); var queue=new ArrayDeque<Integer>(); queue.add(i);
                while(!queue.isEmpty()) {
                    int n=queue.remove(); if(!seen.add(n)) continue;
                    if(n<roots) found.add(n); else for(int p:parents[n]) queue.add(p);
                }
                expected=found.size()==1 ? found.iterator().next() : -1;
            }
            Local actual=replacements.get(locals[i]);
            if(actual != (expected < 0 ? null : locals[expected])) throw new AssertionError("phi " + i + " expected root " + expected);
        }
    }
    public static void main(String[] args) throws Exception {
        var random=new Random(412);
        for(int trial=0;trial<400;trial++) {
            int[][] graph=new int[30][];
            for(int i=0;i<30;i++) {
                graph[i]=new int[random.nextInt(5)];
                for(int j=0;j<graph[i].length;j++) graph[i][j]=random.nextInt(30);
            }
            check(graph,3,true);
        }
        int[][] chain=new int[30000][]; chain[0]=new int[0];
        for(int i=1;i<chain.length;i++) chain[i]=new int[]{i-1, i};
        check(chain,1,false);
        System.out.println("PhiMemoryTest passed: 400 cyclic graphs and 30,000-node chain");
    }
}
